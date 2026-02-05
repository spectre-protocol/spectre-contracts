// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

/// @notice Interface for GrimHook stealth recipient
interface IGrimHook {
    function consumeStealthRecipient(address sender) external returns (address);
}

/// @title PoolTestHelper
/// @notice Helper contract to interact with Uniswap v4 pools for testing
/// @dev Implements IUnlockCallback to perform operations within PoolManager
contract PoolTestHelper is IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    IPoolManager public immutable poolManager;

    // Temporary storage for callback data
    bytes private callbackData;

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    /// @notice Initialize a pool
    function initializePool(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick) {
        return poolManager.initialize(key, sqrtPriceX96);
    }

    /// @notice Add liquidity to a pool
    function addLiquidity(
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1,
        address from
    ) external payable returns (BalanceDelta delta) {
        callbackData = abi.encode(
            CallbackAction.ADD_LIQUIDITY,
            abi.encode(key, tickLower, tickUpper, amount0, amount1, from)
        );
        bytes memory result = poolManager.unlock(callbackData);
        return abi.decode(result, (BalanceDelta));
    }

    /// @notice Execute a swap
    function swap(
        PoolKey memory key,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes memory hookData,
        address from
    ) external returns (BalanceDelta delta) {
        callbackData = abi.encode(
            CallbackAction.SWAP,
            abi.encode(key, zeroForOne, amountSpecified, sqrtPriceLimitX96, hookData, from)
        );
        bytes memory result = poolManager.unlock(callbackData);
        return abi.decode(result, (BalanceDelta));
    }

    enum CallbackAction {
        ADD_LIQUIDITY,
        SWAP
    }

    /// @notice Callback from PoolManager
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(poolManager), "Only PoolManager");

        (CallbackAction action, bytes memory params) = abi.decode(data, (CallbackAction, bytes));

        if (action == CallbackAction.ADD_LIQUIDITY) {
            return _addLiquidityCallback(params);
        } else if (action == CallbackAction.SWAP) {
            return _swapCallback(params);
        }

        revert("Unknown action");
    }

    function _addLiquidityCallback(bytes memory params) internal returns (bytes memory) {
        (PoolKey memory key, int24 tickLower, int24 tickUpper, uint256 amount0, uint256 amount1, address from) =
            abi.decode(params, (PoolKey, int24, int24, uint256, uint256, address));

        // Calculate liquidity from amounts
        uint128 liquidity = _calculateLiquidity(amount0, amount1, tickLower, tickUpper);

        // Modify position
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            ""
        );

        // Settle tokens
        _settleDeltas(key, delta, from);

        return abi.encode(delta);
    }

    function _swapCallback(bytes memory params) internal returns (bytes memory) {
        (
            PoolKey memory key,
            bool zeroForOne,
            int256 amountSpecified,
            uint160 sqrtPriceLimitX96,
            bytes memory hookData,
            address from
        ) = abi.decode(params, (PoolKey, bool, int256, uint160, bytes, address));

        // Execute swap
        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            hookData
        );

        // Check if hook set a stealth recipient for private swap
        address stealthRecipient = address(0);
        if (address(key.hooks) != address(0) && hookData.length > 0) {
            // Try to get stealth recipient from hook
            try IGrimHook(address(key.hooks)).consumeStealthRecipient(address(this)) returns (address recipient) {
                stealthRecipient = recipient;
            } catch {}
        }

        // Settle tokens - route output to stealth address if set
        _settlePrivateSwapDeltas(key, delta, from, stealthRecipient, zeroForOne);

        return abi.encode(delta);
    }

    function _settlePrivateSwapDeltas(
        PoolKey memory key,
        BalanceDelta delta,
        address from,
        address stealthRecipient,
        bool zeroForOne
    ) internal {
        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();

        // Determine output currency based on swap direction
        // zeroForOne: input is currency0, output is currency1
        // !zeroForOne: input is currency1, output is currency0

        // Settle currency0
        if (delta0 < 0) {
            // We owe the pool, transfer from user
            _settle(key.currency0, from, uint128(-delta0));
        } else if (delta0 > 0) {
            // Pool owes us - route to stealth if this is the output and stealth is set
            address recipient = (!zeroForOne && stealthRecipient != address(0)) ? stealthRecipient : from;
            _take(key.currency0, recipient, uint128(delta0));
        }

        // Settle currency1
        if (delta1 < 0) {
            // We owe the pool, transfer from user
            _settle(key.currency1, from, uint128(-delta1));
        } else if (delta1 > 0) {
            // Pool owes us - route to stealth if this is the output and stealth is set
            address recipient = (zeroForOne && stealthRecipient != address(0)) ? stealthRecipient : from;
            _take(key.currency1, recipient, uint128(delta1));
        }
    }

    function _settleDeltas(PoolKey memory key, BalanceDelta delta, address from) internal {
        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();

        // Settle currency0
        if (delta0 < 0) {
            // We owe the pool, transfer from user
            _settle(key.currency0, from, uint128(-delta0));
        } else if (delta0 > 0) {
            // Pool owes us, take from pool
            _take(key.currency0, from, uint128(delta0));
        }

        // Settle currency1
        if (delta1 < 0) {
            // We owe the pool, transfer from user
            _settle(key.currency1, from, uint128(-delta1));
        } else if (delta1 > 0) {
            // Pool owes us, take from pool
            _take(key.currency1, from, uint128(delta1));
        }
    }

    function _settle(Currency currency, address from, uint128 amount) internal {
        if (currency.isAddressZero()) {
            poolManager.settle{value: amount}();
        } else {
            poolManager.sync(currency);
            IERC20(Currency.unwrap(currency)).transferFrom(from, address(poolManager), amount);
            poolManager.settle();
        }
    }

    function _take(Currency currency, address to, uint128 amount) internal {
        poolManager.take(currency, to, amount);
    }

    function _calculateLiquidity(uint256 amount0, uint256 amount1, int24 tickLower, int24 tickUpper)
        internal
        pure
        returns (uint128)
    {
        // Simplified liquidity calculation for testing
        // In production, use LiquidityAmounts library
        uint160 sqrtRatioAX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtPriceAtTick(tickUpper);

        // For simplicity, use the smaller of the two implied liquidities
        uint256 liquidity0 = (amount0 * uint256(sqrtRatioAX96)) / (1 << 96);
        uint256 liquidity1 = (amount1 * uint256(sqrtRatioBX96)) / (1 << 96);

        uint256 liquidity = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
        if (liquidity > type(uint128).max) liquidity = type(uint128).max;

        return uint128(liquidity);
    }

    receive() external payable {}
}
