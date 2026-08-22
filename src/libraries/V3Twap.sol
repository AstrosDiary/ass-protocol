// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IPancakeV3PoolMinimal {
    function observe(uint32[] calldata secondsAgos)
        external view returns (int56[] memory tickCumulatives, uint160[] memory);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

/// @notice Minimal TWAP quoting for Pancake V3 pools. Vendored from canonical
/// Uniswap v3-core/periphery (FullMath.mulDiv, TickMath.getSqrtRatioAtTick,
/// OracleLibrary.consult/getQuoteAtTick), trimmed to the read-only surface.
library V3Twap {
    error InvalidTick();
    error ZeroWindow();

    /// @dev canonical 512-bit mulDiv (Remco Bloemen / Uniswap FullMath, 0.8 port)
    function mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            uint256 prod0; uint256 prod1;
            assembly { let mm := mulmod(a, b, not(0)) prod0 := mul(a, b) prod1 := sub(sub(mm, prod0), lt(mm, prod0)) }
            if (prod1 == 0) { require(denominator > 0); assembly { result := div(prod0, denominator) } return result; }
            require(denominator > prod1);
            uint256 remainder;
            assembly { remainder := mulmod(a, b, denominator) prod1 := sub(prod1, gt(remainder, prod0)) prod0 := sub(prod0, remainder) }
            uint256 twos = denominator & (~denominator + 1);
            assembly { denominator := div(denominator, twos) prod0 := div(prod0, twos) twos := add(div(sub(0, twos), twos), 1) }
            prod0 |= prod1 * twos;
            uint256 inv = (3 * denominator) ^ 2;
            inv *= 2 - denominator * inv; inv *= 2 - denominator * inv; inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv; inv *= 2 - denominator * inv; inv *= 2 - denominator * inv;
            result = prod0 * inv;
        }
    }

    /// @dev canonical TickMath.getSqrtRatioAtTick (0.8 port, unchecked)
    function getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        unchecked {
            uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
            if (absTick > 887272) revert InvalidTick();
            uint256 ratio = absTick & 0x1 != 0 ? 0xfffcb933bd6fad37aa2d162d1a594001 : 0x100000000000000000000000000000000;
            if (absTick & 0x2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
            if (absTick & 0x4 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
            if (absTick & 0x8 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
            if (absTick & 0x10 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
            if (absTick & 0x20 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
            if (absTick & 0x40 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
            if (absTick & 0x80 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
            if (absTick & 0x100 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
            if (absTick & 0x200 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
            if (absTick & 0x400 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
            if (absTick & 0x800 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
            if (absTick & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
            if (absTick & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
            if (absTick & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
            if (absTick & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
            if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
            if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
            if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
            if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;
            if (tick > 0) ratio = type(uint256).max / ratio;
            sqrtPriceX96 = uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
        }
    }

    /// @dev OracleLibrary.consult: arithmetic mean tick over [now-window, now]
    function meanTick(address pool, uint32 window) internal view returns (int24 tick) {
        if (window == 0) revert ZeroWindow();
        uint32[] memory ago = new uint32[](2);
        ago[0] = window; ago[1] = 0;
        (int56[] memory cum,) = IPancakeV3PoolMinimal(pool).observe(ago);
        int56 delta = cum[1] - cum[0];
        tick = int24(delta / int56(uint56(window)));
        if (delta < 0 && (delta % int56(uint56(window)) != 0)) tick--; // round toward -inf
    }

    /// @dev OracleLibrary.getQuoteAtTick
    function quoteAtTick(int24 tick, uint128 baseAmount, address baseToken, address quoteToken)
        internal pure returns (uint256 quoteAmount)
    {
        uint160 sqrtRatioX96 = getSqrtRatioAtTick(tick);
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            quoteAmount = baseToken < quoteToken
                ? mulDiv(ratioX192, baseAmount, 1 << 192)
                : mulDiv(1 << 192, baseAmount, ratioX192);
        } else {
            uint256 ratioX128 = mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
            quoteAmount = baseToken < quoteToken
                ? mulDiv(ratioX128, baseAmount, 1 << 128)
                : mulDiv(1 << 128, baseAmount, ratioX128);
        }
    }

    /// @notice TWAP-quote an exact-input amount along a multi-hop route.
    function quoteRoute(address[] memory pools, address[] memory tokens, uint32 window, uint256 amountIn)
        internal view returns (uint256 amountOut)
    {
        amountOut = amountIn;
        for (uint256 i; i < pools.length; ++i) {
            require(amountOut <= type(uint128).max, "amt overflow");
            amountOut = quoteAtTick(meanTick(pools[i], window), uint128(amountOut), tokens[i], tokens[i + 1]);
        }
    }
}