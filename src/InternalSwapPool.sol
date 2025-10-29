// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {SwapMath} from '@uniswap/v4-core/src/libraries/SwapMath.sol';
import {Hooks, IHooks} from '@uniswap/v4-core/src/libraries/Hooks.sol';
import {BalanceDelta} from '@uniswap/v4-core/src/types/BalanceDelta.sol';
import {Currency, CurrencyLibrary} from '@uniswap/v4-core/src/types/Currency.sol';
import {PoolId, PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {BeforeSwapDelta, toBeforeSwapDelta} from '@uniswap/v4-core/src/types/BeforeSwapDelta.sol';
import {ModifyLiquidityParams, SwapParams} from '@uniswap/v4-core/src/types/PoolOperation.sol';
import {StateLibrary} from '@uniswap/v4-core/src/libraries/StateLibrary.sol';
import {CurrencySettler} from '@uniswap/v4-core/test/utils/CurrencySettler.sol';

import {IERC20Minimal} from '@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol';
import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';

import {BaseHook} from 'v4-periphery/src/utils/BaseHook.sol';


/**
 * This contract sets up our Uniswap V4 integration, allowing for hook logic to be applied
 * to our pools. This also implements pool fee management and LP reward distribution through
 * the `donate` logic.
 *
 * When fees are collected they will be distributed between the Uniswap V4 pool that was
 * interacted with, to promote liquidity, and an optional beneficiary.
 *
 * The calculation of the fees paid into the {FeeCollector} should be undertaken by the
 * individual contracts that are calling it.
 */
contract InternalSwapPool is BaseHook {

    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// Minimum threshold for donations
    uint public constant DONATE_THRESHOLD_MIN = 0.0001 ether;

    /// Maximum threshold for donations
    uint public constant DONATE_THRESHOLD_MAX = 1 ether;

    /// The native token address
    address public immutable nativeToken;

    /**
     * The amount of claimable tokens that are available to be `distributed` for a `PoolId`.
     *
     * @param amount0 The amount of currency0 that is available to be distributed
     * @param amount1 The amount of currency1 that is available to be distributed
     */
    struct ClaimableFees {
        uint amount0;
        uint amount1;
    }

    /// Maps the amount of claimable tokens that are available to be `distributed`
    /// for a `PoolId`.
    mapping (PoolId _poolId => ClaimableFees _fees) internal _poolFees;

    /**
     * Sets our immutable {PoolManager} contract reference, used to initialise the BaseHook,
     * and also validates that the contract implementing this adheres to the hook address
     * validation.
     */
    constructor (address _poolManager, address _nativeToken) BaseHook(IPoolManager(_poolManager)) {
        nativeToken = _nativeToken;
    }

    /**
     * Provides the {ClaimableFees} for a pool.
     *
     * @param _poolKey The PoolKey of the pool
     *
     * @return The {ClaimableFees} for the pool
     */
    function poolFees(PoolKey calldata _poolKey) public view returns (ClaimableFees memory) {
        return _poolFees[_poolKey.toId()];
    }

    /**
     * When fees are collected against a collection it is sent as ETH in a payable
     * transaction to this function. This then handles the distribution of the
     * allocation between the `_poolId` specified and, if set, a percentage for
     * the `beneficiary`.
     *
     * Our `amount0` must always refer to the amount of the native token provided. The
     * `amount1` will always be the underlying {CollectionToken}. The internal logic of
     * this function will rearrange them to match the `PoolKey` if needed.
     *
     * @param _poolKey The PoolKey of the pool
     * @param _amount0 The amount of currency0 to deposit
     * @param _amount1 The amount of currency1 to deposit
     */
    function depositFees(PoolKey calldata _poolKey, uint _amount0, uint _amount1) public {
        if (_amount0 != 0) {
            _poolFees[_poolKey.toId()].amount0 += _amount0;
            IERC20Minimal(Currency.unwrap(_poolCurrencyFlipped(_poolKey) ? _poolKey.currency1 : _poolKey.currency0)).transferFrom(msg.sender, address(this), _amount0);
        }

        if (_amount1 != 0) {
            _poolFees[_poolKey.toId()].amount1 += _amount1;
            IERC20Minimal(Currency.unwrap(_poolCurrencyFlipped(_poolKey) ? _poolKey.currency0 : _poolKey.currency1)).transferFrom(msg.sender, address(this), _amount1);
        }
    }

    /**
     * Takes a collection address and, if there is sufficient fees available to
     * claim, will call the `donate` function against the mapped Uniswap V4 pool.
     *
     * @dev This call could be checked in a Uniswap V4 interactions hook to
     * dynamically process fees when they hit a threshold.
     *
     * @param _poolKey The PoolKey reference that will have fees distributed
     */
    function _distributeFees(PoolKey calldata _poolKey) internal {
        // Get the amount of the native token available to donate
        PoolId poolId = _poolKey.toId();
        uint donateAmount = _poolFees[poolId].amount0;

        // Ensure that the collection has sufficient fees available
        if (donateAmount < DONATE_THRESHOLD_MIN) {
            return;
        }

        // Cap our donation amount at the max value
        donateAmount = (donateAmount > DONATE_THRESHOLD_MAX) ? DONATE_THRESHOLD_MAX : donateAmount;

        // Make our donation to the pool, with the beneficiary amount remaining in the
        // contract ready to be claimed.
        if (donateAmount > 0) {
            // Determine whether the currency is flipped to determine which is the donation side
            (uint amount0, uint amount1) = (_poolCurrencyFlipped(_poolKey)) ? (uint(0), donateAmount) : (donateAmount, uint(0));
            BalanceDelta delta = poolManager.donate(_poolKey, amount0, amount1, '');

            // Check the native delta amounts that we need to transfer from the contract
            if (delta.amount0() < 0) {
                _poolKey.currency0.settle(poolManager, address(this), uint(uint128(-delta.amount0())), false);
            }

            if (delta.amount1() < 0) {
                _poolKey.currency1.settle(poolManager, address(this), uint(uint128(-delta.amount1())), false);
            }
        }

        // Reduce our available fees
        _poolFees[poolId].amount0 -= donateAmount;
    }

    /**
     * Before a swap is made, we pull in the dynamic pool fee that we have set to ensure it is
     * applied to the tx.
     *
     * We also see if we have any token1 fee tokens that we can use to fill the swap before it
     * hits the Uniswap pool. This prevents the pool from being affected and reduced gas costs.
     * This also allows us to benefit from the Uniswap routing infrastructure.
     *
     * @param sender The initial msg.sender for the swap call
     * @param key The key for the pool
     * @param params The parameters for the swap
     * @param hookData Arbitrary data handed into the PoolManager by the swapper to be be passed on to the hook
     *
     * @return selector_ The function selector for the hook
     * @return beforeSwapDelta_ The hook's delta in specified and unspecified currencies. Positive: the hook is owed/took currency, negative: the hook owes/sent currency
     * @return swapFee_ The percentage fee applied to our swap
     */
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData) internal override returns (bytes4 selector_, BeforeSwapDelta beforeSwapDelta_, uint24 swapFee_) {
        // Ensure our dynamic fees are set to the correct amount
        PoolId poolId = key.toId();
        swapFee_ = 10000;

        // Frontrun uniswap to sell token1 amounts from our fees into token0 ahead of
        // our fee distribution calls. This acts as a partial orderbook to remove slippage
        // impact against our pool.

        // We want to check if out token0 is the eth equivalent, or if it has swapped to token1
        bool trigger = _poolCurrencyFlipped(key) ? !params.zeroForOne : params.zeroForOne;
        if (trigger && _poolFees[poolId].amount1 != 0) {
            // Set up our internal logic variables
            uint tokenIn;
            uint ethOut;

            // Get the current price for our pool
            (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);

            // We need to vary our swap logic based on if we have an exact input or output
            if (params.amountSpecified >= 0) {
                // token0 for token1 with Exact Output for Input (amountSpecified = positive value representing token1):
                // -> the user is specifying their swap amount in terms of token1, so the specifiedCurrency is token1
                // -> the unspecifiedCurrency is token0

                // Since we have an amount of token1 specified, we can determine the maximum
                // amount that we can transact from our pool fees. We do this by taking the
                // max value of either the pool token1 fees or the amount specified to swap for.
                uint amountSpecified = (uint(params.amountSpecified) > _poolFees[poolId].amount1) ? _poolFees[poolId].amount1 : uint(params.amountSpecified);

                // Capture the amount of ETH (token0) required at the current pool state to purchase
                // the amount of token1 speicified, capped by the pool fees available.
                // We don't apply a fee for this as it benefits the ecosystem and essentially performs
                // a free swap benefitting both parties.
                // @dev uint160 sqrtPriceNextX96, uint256 amountIn, uint256 amountOut, uint256 feeAmount
                (, ethOut, tokenIn, ) = SwapMath.computeSwapStep({
                    sqrtPriceCurrentX96: sqrtPriceX96,
                    sqrtPriceTargetX96: params.sqrtPriceLimitX96,
                    liquidity: poolManager.getLiquidity(poolId),
                    amountRemaining: int(amountSpecified),
                    feePips: 0
                });

                // Update our hook delta to reduce the upcoming swap amount to show that we have
                // already spent some of the ETH and received some of the underlying ERC20.
                // Specified = exact output (T)
                // Unspecified = ETH
                beforeSwapDelta_ = toBeforeSwapDelta(-int128(int(tokenIn)), int128(int(ethOut)));
            } else {
                // ETH for token1 with Exact Input for Output (amountSpecified = negative value representing ETH):
                // -> the user is specifying their swap amount in terms of ETH, so the specifiedCurrency is ETH
                // -> the unspecifiedCurrency is token1

                // Since we have an amount of token0 specified, we need to just determine the
                // amount that we would receive if we were to convert all of the pool fees. When
                // we have this value we can find the amount of ETH that would be required to fill
                // this amount and then determine if we can fill in it's entirity, or would require
                // us to calculate a discounted amount.
                (, ethOut, tokenIn, ) = SwapMath.computeSwapStep({
                    sqrtPriceCurrentX96: sqrtPriceX96,
                    sqrtPriceTargetX96: params.sqrtPriceLimitX96,
                    liquidity: poolManager.getLiquidity(poolId),
                    amountRemaining: int(_poolFees[poolId].amount1),
                    feePips: 0
                });

                // Now that we know how much `ethOut` would be required to fill all of the pool
                // token1 fees (`tokenIn`), we can see if we can fund enough using the token0
                // provided.
                if (ethOut > uint(-params.amountSpecified)) {
                    // We need to calculate the percentage of token0 and then apply that same
                    // percentage reduction to the `tokenIn` amount. This will allow us to
                    // successfully fill the order.
                    uint percentage = (uint(-params.amountSpecified) * 1e18) / ethOut;

                    // Apply the same percentage reduction to tokenIn
                    tokenIn = (tokenIn * percentage) / 1e18;
                }

                // Update our hook delta to reduce the upcoming swap amount to show that we have
                // already spent some of the ETH and received some of the underlying ERC20.
                // Specified = exact input (ETH)
                // Unspecified = token1
                beforeSwapDelta_ = toBeforeSwapDelta(int128(int(ethOut)), -int128(int(tokenIn)));
            }

            // Reduce the amount of fees that have been extracted from the pool and converted
            // into ETH fees.
            _poolFees[poolId].amount0 += ethOut;
            _poolFees[poolId].amount1 -= tokenIn;

            // Sync our tokens
            poolManager.sync(key.currency0);
            poolManager.sync(key.currency1);

            // Transfer the tokens to our PoolManager, which will later swap them to our user
            if (_poolCurrencyFlipped(key)) {
                poolManager.take(key.currency1, address(this), ethOut);
                key.currency0.settle(poolManager, address(this), tokenIn, false);
            } else {
                poolManager.take(key.currency0, address(this), ethOut);
                key.currency1.settle(poolManager, address(this), tokenIn, false);
            }
        }

        // Set our return selector
        selector_ = IHooks.beforeSwap.selector;
    }

    /**
     * Once a swap has been made, we distribute fees to our LPs and emit our price update event.
     *
     * @param sender The initial msg.sender for the swap call
     * @param key The key for the pool
     * @param params The parameters for the swap
     * @param delta The amount owed to the caller (positive) or owed to the pool (negative)
     * @param hookData Arbitrary data handed into the PoolManager by the swapper to be be passed on to the hook
     *
     * @return selector_ The function selector for the hook
     * @return hookDeltaSpecified_ The hook's delta in unspecified currency. Positive: the hook is owed/took currency, negative: the hook owes/sent currency
     */
    function _afterSwap(address sender, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata hookData) internal override returns (bytes4 selector_, int128 hookDeltaSpecified_) {
        // Distribute fees to our LPs
        _distributeFees(key);
        selector_ = IHooks.afterSwap.selector;
    }

    /**
     * Before a liquidity position is modified, we distribute fees before they can come in to
     * take a share of fees that they have not earned.
     */
    function _beforeAddLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata params, bytes calldata hookData) internal override returns (bytes4) {
        // Distribute fees to our LPs before someone can come in to take an unearned share
        _distributeFees(key);
        return IHooks.beforeAddLiquidity.selector;
    }

    /**
     * Before liquidity has been removed, we distribute fees.
     *
     * @param sender The initial msg.sender for the remove liquidity call
     * @param key The key for the pool
     * @param params The parameters for removing liquidity
     * @param hookData Arbitrary data handed into the PoolManager by the liquidty provider to be be passed on to the hook
     *
     * @return selector_ The function selector for the hook
     */
    function _beforeRemoveLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata params, bytes calldata hookData) internal override returns (bytes4 selector_) {
        // Distribute fees to our LPs
        _distributeFees(key);
        selector_ = IHooks.beforeRemoveLiquidity.selector;
    }

    /**
     * Checks if the currency is flipped.
     */
    function _poolCurrencyFlipped(PoolKey calldata _poolKey) internal returns (bool) {
        return nativeToken == Currency.unwrap(_poolKey.currency1);
    }

    /**
     * This function defines the hooks that are required, and also importantly those which are
     * not, by our contract. This output determines the contract address that the deployment
     * must conform to and is validated in the constructor of this contract.
     *
     * @dev 0010 1011 0011 00
     */
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

}
