// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {console2} from "forge-std/console2.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import "../../BaseTest.sol";
import {ERC20Mock} from "../../mocks/ERC20Mock.sol";
import {LDFType} from "../../../src/types/LDFType.sol";
import {UniformDistribution} from "../../../src/ldf/UniformDistribution.sol";
import {CarpetedGeometricDistribution} from "../../../src/ldf/CarpetedGeometricDistribution.sol";
import {DistributionType, CuratedDistribution} from "../../../src/ldf/managed/CuratedDistribution.sol";
import {CarpetedDoubleGeometricDistribution} from "../../../src/ldf/CarpetedDoubleGeometricDistribution.sol";

contract CuratedDistributionHarness is CuratedDistribution {
    constructor(address hub_, address hook_, address quoter_) CuratedDistribution(hub_, hook_, quoter_) {}

    function decodeLdfParams(bytes32 ldfParams)
        external
        pure
        returns (DistributionType distro, bytes28 baseLdfParams)
    {
        (distro, baseLdfParams) = _decodeLdfParams(ldfParams);
    }

    function decodeState(bytes32 ldfState)
        external
        pure
        returns (bool initialized, int24 lastMinTick, DistributionType lastDistributionType, bytes28 lastBaseLdfParams)
    {
        (initialized, lastMinTick, lastDistributionType, lastBaseLdfParams) = _decodeState(ldfState);
    }

    function sanitizeBaseLdfParams(DistributionType distro, bytes28 baseLdfParams) external pure returns (bytes28) {
        return _sanitizeBaseLdfParams(distro, baseLdfParams);
    }
}

contract CuratedDistributionTest is BaseTest {
    using PoolIdLibrary for PoolKey;

    uint256 internal constant MIN_ALPHA = 1e3;
    uint256 internal constant MAX_ALPHA = 12e8;
    uint256 internal constant Q96 = 2 ** 96;

    IBunniToken internal bunniToken;
    PoolKey internal key;
    CuratedDistributionHarness internal curatedLdf;

    function setUp() public override {
        super.setUp();

        // Deploy curated LDF
        curatedLdf = new CuratedDistributionHarness(address(hub), address(bunniHook), address(quoter));

        // Deploy Bunni pool with LDF
        (bunniToken, key) = _deployPoolAndInitLiquidity(curatedLdf, _createDefaultParams());
    }

    function test_shouldSurgeOnParamsUpdate() public {
        // query LDF to initialize state
        vm.prank(address(hub));
        (,,, bytes32 state, bool shouldSurge) = ldf.query({
            key: key,
            roundedTick: 0,
            twapTick: 0,
            spotPriceTick: 0,
            ldfParams: _createDefaultParams(),
            ldfState: bytes32(0)
        });

        // should not surge on init
        assertFalse(shouldSurge, "Should not surge on init");

        // construct new params
        int24 minTick = -100;
        int24 length = 10;
        uint32 alpha = 1.2e8;
        uint32 weightCarpet = 1e6;
        bytes28 newBaseParams =
            bytes28(abi.encodePacked(ShiftMode.STATIC, minTick, int16(length), uint32(alpha), uint32(weightCarpet)));

        // set new params
        curatedLdf.setLdfParams(key, DistributionType.CARPETED_GEOMETRIC, newBaseParams);

        // query LDF
        vm.prank(address(hub));
        (,,, state, shouldSurge) = curatedLdf.query({
            key: key,
            roundedTick: 0,
            twapTick: 0,
            spotPriceTick: 0,
            ldfParams: _createDefaultParams(),
            ldfState: state
        });
        assertTrue(shouldSurge, "Should surge on params update");
    }

    function test_ldfMatchesBaseDistributions_uniform_static(
        int24 currentTick,
        int24 twapTick,
        int24 tickLower,
        int24 tickUpper
    ) public {
        int24 tickSpacing = TICK_SPACING;
        (int24 minUsableTick, int24 maxUsableTick) =
            (TickMath.minUsableTick(tickSpacing), TickMath.maxUsableTick(tickSpacing));
        tickLower = roundTickSingle(int24(bound(tickLower, minUsableTick, maxUsableTick - tickSpacing)), tickSpacing);
        tickUpper = roundTickSingle(int24(bound(tickUpper, tickLower + tickSpacing, maxUsableTick)), tickSpacing);
        currentTick = int24(bound(currentTick, minUsableTick, maxUsableTick));
        twapTick = int24(bound(twapTick, minUsableTick, maxUsableTick));
        int24 roundedTick = roundTickSingle(currentTick, tickSpacing);

        // deploy uniform LDF
        ILiquidityDensityFunction uniformLdf =
            new UniformDistribution(address(hub), address(bunniHook), address(quoter));

        // construct params
        bytes28 baseParams = bytes28(abi.encodePacked(ShiftMode.STATIC, tickLower, tickUpper));

        // set params
        curatedLdf.setLdfParams(key, DistributionType.UNIFORM, baseParams);

        // query LDF
        vm.prank(address(hub));
        (uint256 actualDensity, uint256 actualCumAmount0, uint256 actualCumAmount1,,) = curatedLdf.query({
            key: key,
            roundedTick: roundedTick,
            twapTick: twapTick,
            spotPriceTick: currentTick,
            ldfParams: _createDefaultParams(),
            ldfState: bytes32(0)
        });

        // query base distribution
        vm.prank(address(hub));
        (uint256 expectedDensity, uint256 expectedCumAmount0, uint256 expectedCumAmount1,,) = uniformLdf.query({
            key: key,
            roundedTick: roundedTick,
            twapTick: twapTick,
            spotPriceTick: currentTick,
            ldfParams: baseParams,
            ldfState: bytes32(0)
        });

        assertEq(actualDensity, expectedDensity, "Density mismatch");
        assertEq(actualCumAmount0, expectedCumAmount0, "Cumulative amount 0 mismatch");
        assertEq(actualCumAmount1, expectedCumAmount1, "Cumulative amount 1 mismatch");
    }

    function test_ldfMatchesBaseDistributions_uniform_dynamic(
        int24 currentTick,
        int24 twapTick,
        int24 offset,
        int24 length,
        uint8 shiftMode_
    ) public {
        shiftMode_ = uint8(bound(shiftMode_, 0, 2));
        ShiftMode shiftMode = ShiftMode(shiftMode_);

        int24 tickSpacing = TICK_SPACING;
        (int24 minUsableTick, int24 maxUsableTick) =
            (TickMath.minUsableTick(tickSpacing), TickMath.maxUsableTick(tickSpacing));
        offset = roundTickSingle(int24(bound(offset, minUsableTick, maxUsableTick)), tickSpacing);
        length = roundTickSingle(int24(bound(length, tickSpacing, maxUsableTick)), tickSpacing) / tickSpacing;
        currentTick = int24(bound(currentTick, minUsableTick, maxUsableTick));
        twapTick = int24(bound(twapTick, minUsableTick, maxUsableTick));
        int24 roundedTick = roundTickSingle(currentTick, tickSpacing);

        // deploy uniform LDF
        ILiquidityDensityFunction uniformLdf =
            new UniformDistribution(address(hub), address(bunniHook), address(quoter));

        // construct params
        bytes28 baseParams = bytes28(abi.encodePacked(shiftMode, offset, length));

        // set params
        curatedLdf.setLdfParams(key, DistributionType.UNIFORM, baseParams);

        // query LDF
        vm.prank(address(hub));
        (uint256 actualDensity, uint256 actualCumAmount0, uint256 actualCumAmount1,,) = curatedLdf.query({
            key: key,
            roundedTick: roundedTick,
            twapTick: twapTick,
            spotPriceTick: currentTick,
            ldfParams: _createDefaultParams(),
            ldfState: bytes32(0)
        });

        // query base distribution
        vm.prank(address(hub));
        (uint256 expectedDensity, uint256 expectedCumAmount0, uint256 expectedCumAmount1,,) = uniformLdf.query({
            key: key,
            roundedTick: roundedTick,
            twapTick: twapTick,
            spotPriceTick: currentTick,
            ldfParams: baseParams,
            ldfState: bytes32(0)
        });

        assertEq(actualDensity, expectedDensity, "Density mismatch");
        assertEq(actualCumAmount0, expectedCumAmount0, "Cumulative amount 0 mismatch");
        assertEq(actualCumAmount1, expectedCumAmount1, "Cumulative amount 1 mismatch");
    }

    function test_ldfMatchesBaseDistributions_geometric_static(
        int24 currentTick,
        int24 twapTick,
        int24 minTick,
        int24 length,
        uint32 alpha,
        uint32 weightCarpet
    ) public {
        alpha = uint32(bound(alpha, MIN_ALPHA, MAX_ALPHA));
        vm.assume(alpha != 1e8); // 1e8 is a special case that causes overflow
        weightCarpet = uint32(bound(weightCarpet, 1, type(uint32).max));
        int24 tickSpacing = TICK_SPACING;
        (int24 minUsableTick, int24 maxUsableTick) =
            (TickMath.minUsableTick(tickSpacing), TickMath.maxUsableTick(tickSpacing));
        minTick = roundTickSingle(int24(bound(minTick, minUsableTick, maxUsableTick - 2 * tickSpacing)), tickSpacing);
        length = int24(bound(length, 1, (maxUsableTick - minTick) / tickSpacing - 1));
        currentTick = int24(bound(currentTick, minUsableTick, maxUsableTick));
        twapTick = int24(bound(twapTick, minUsableTick, maxUsableTick));
        int24 roundedTick = roundTickSingle(currentTick, tickSpacing);

        // deploy geometric LDF
        ILiquidityDensityFunction geometricLdf =
            new CarpetedGeometricDistribution(address(hub), address(bunniHook), address(quoter));

        // construct params
        bytes28 baseParams =
            bytes28(abi.encodePacked(ShiftMode.STATIC, minTick, int16(length), uint32(alpha), uint32(weightCarpet)));
        vm.assume(geometricLdf.isValidParams(key, 0, baseParams, LDFType.STATIC));

        // set params
        curatedLdf.setLdfParams(key, DistributionType.CARPETED_GEOMETRIC, baseParams);

        // query LDF
        vm.prank(address(hub));
        (uint256 actualDensity, uint256 actualCumAmount0, uint256 actualCumAmount1,,) = curatedLdf.query({
            key: key,
            roundedTick: roundedTick,
            twapTick: twapTick,
            spotPriceTick: currentTick,
            ldfParams: _createDefaultParams(),
            ldfState: bytes32(0)
        });

        // query base distribution
        vm.prank(address(hub));
        (uint256 expectedDensity, uint256 expectedCumAmount0, uint256 expectedCumAmount1,,) = geometricLdf.query({
            key: key,
            roundedTick: roundedTick,
            twapTick: twapTick,
            spotPriceTick: currentTick,
            ldfParams: baseParams,
            ldfState: bytes32(0)
        });

        assertEq(actualDensity, expectedDensity, "Density mismatch");
        assertEq(actualCumAmount0, expectedCumAmount0, "Cumulative amount 0 mismatch");
        assertEq(actualCumAmount1, expectedCumAmount1, "Cumulative amount 1 mismatch");
    }

    function test_ldfMatchesBaseDistributions_geometric_dynamic(
        int24 currentTick,
        int24 twapTick,
        int24 minTick,
        int24 length,
        uint32 alpha,
        uint32 weightCarpet,
        uint8 shiftMode_
    ) public {
        shiftMode_ = uint8(bound(shiftMode_, 0, 2));
        ShiftMode shiftMode = ShiftMode(shiftMode_);

        int24 tickSpacing = TICK_SPACING;
        (int24 minUsableTick, int24 maxUsableTick) =
            (TickMath.minUsableTick(tickSpacing), TickMath.maxUsableTick(tickSpacing));
        minTick = roundTickSingle(int24(bound(minTick, minUsableTick, maxUsableTick - 2 * tickSpacing)), tickSpacing);
        length = int24(bound(length, 1, (maxUsableTick - minTick) / tickSpacing - 1));
        alpha = uint32(bound(alpha, MIN_ALPHA, MAX_ALPHA));
        vm.assume(alpha != 1e8); // 1e8 is a special case that causes overflow
        weightCarpet = uint32(bound(weightCarpet, 1, type(uint32).max));
        currentTick = int24(bound(currentTick, minUsableTick, maxUsableTick));
        twapTick = int24(bound(twapTick, minUsableTick, maxUsableTick));
        int24 roundedTick = roundTickSingle(currentTick, tickSpacing);

        // deploy geometric LDF
        ILiquidityDensityFunction geometricLdf =
            new CarpetedGeometricDistribution(address(hub), address(bunniHook), address(quoter));

        // construct params
        bytes28 baseParams =
            bytes28(abi.encodePacked(shiftMode, minTick, int16(length), uint32(alpha), uint32(weightCarpet)));
        vm.assume(geometricLdf.isValidParams(key, 15 minutes, baseParams, LDFType.DYNAMIC_AND_STATEFUL));

        // set params
        curatedLdf.setLdfParams(key, DistributionType.CARPETED_GEOMETRIC, baseParams);

        // query LDF
        vm.prank(address(hub));
        (uint256 actualDensity, uint256 actualCumAmount0, uint256 actualCumAmount1,,) = curatedLdf.query({
            key: key,
            roundedTick: roundedTick,
            twapTick: twapTick,
            spotPriceTick: currentTick,
            ldfParams: _createDefaultParams(),
            ldfState: bytes32(0)
        });

        // query base distribution
        vm.prank(address(hub));
        (uint256 expectedDensity, uint256 expectedCumAmount0, uint256 expectedCumAmount1,,) = geometricLdf.query({
            key: key,
            roundedTick: roundedTick,
            twapTick: twapTick,
            spotPriceTick: currentTick,
            ldfParams: baseParams,
            ldfState: bytes32(0)
        });

        assertEq(actualDensity, expectedDensity, "Density mismatch");
        assertEq(actualCumAmount0, expectedCumAmount0, "Cumulative amount 0 mismatch");
        assertEq(actualCumAmount1, expectedCumAmount1, "Cumulative amount 1 mismatch");
    }

    function test_ldfMatchesBaseDistributions_doubleGeometric_static(
        int24 currentTick,
        int24 twapTick,
        int24 minTick,
        int24 length0,
        int24 length1,
        uint32 alpha0,
        uint32 alpha1,
        uint32 weight0,
        uint32 weight1,
        uint32 weightCarpet
    ) public {
        int24 tickSpacing = TICK_SPACING;
        (int24 minUsableTick, int24 maxUsableTick) =
            (TickMath.minUsableTick(tickSpacing), TickMath.maxUsableTick(tickSpacing));
        minTick = roundTickSingle(int24(bound(minTick, minUsableTick, maxUsableTick - 3 * tickSpacing)), tickSpacing);

        weight0 = uint32(bound(weight0, 1, 1e6));
        weight1 = uint32(bound(weight1, 1, 1e6));

        alpha1 = uint32(bound(alpha1, MIN_ALPHA, MAX_ALPHA));
        vm.assume(alpha1 != 1e8); // 1e8 is a special case that causes overflow
        minTick = roundTickSingle(int24(bound(minTick, minUsableTick, maxUsableTick - 2 * tickSpacing)), tickSpacing);
        length1 = int24(bound(length1, 1, (maxUsableTick - minTick) / tickSpacing - 1));

        alpha0 = uint32(bound(alpha0, MIN_ALPHA, MAX_ALPHA));
        vm.assume(alpha0 != 1e8); // 1e8 is a special case that causes overflow
        length0 = int24(
            bound(
                length0,
                1,
                FixedPointMathLib.max(1, (maxUsableTick - (minTick + length1 * tickSpacing)) / tickSpacing - 1)
            )
        );

        weightCarpet = uint32(bound(weightCarpet, 1, type(uint32).max));

        currentTick = int24(bound(currentTick, minUsableTick, maxUsableTick));
        twapTick = int24(bound(twapTick, minUsableTick, maxUsableTick));
        int24 roundedTick = roundTickSingle(currentTick, tickSpacing);

        // deploy double geometric LDF
        ILiquidityDensityFunction doubleGeometricLdf =
            new CarpetedDoubleGeometricDistribution(address(hub), address(bunniHook), address(quoter));

        // construct params
        bytes28 baseParams = bytes28(
            abi.encodePacked(
                ShiftMode.STATIC,
                int24(minTick),
                int16(length0),
                uint32(alpha0),
                uint32(weight0),
                int16(length1),
                uint32(alpha1),
                uint32(weight1),
                uint32(weightCarpet)
            )
        );
        if (!doubleGeometricLdf.isValidParams(key, 0, baseParams, LDFType.STATIC)) return;

        // set params
        curatedLdf.setLdfParams(key, DistributionType.CARPETED_DOUBLE_GEOMETRIC, baseParams);

        // query LDF
        vm.prank(address(hub));
        (uint256 actualDensity, uint256 actualCumAmount0, uint256 actualCumAmount1,,) = curatedLdf.query({
            key: key,
            roundedTick: roundedTick,
            twapTick: twapTick,
            spotPriceTick: currentTick,
            ldfParams: _createDefaultParams(),
            ldfState: bytes32(0)
        });

        // query base distribution
        vm.prank(address(hub));
        (uint256 expectedDensity, uint256 expectedCumAmount0, uint256 expectedCumAmount1,,) = doubleGeometricLdf.query({
            key: key,
            roundedTick: roundedTick,
            twapTick: twapTick,
            spotPriceTick: currentTick,
            ldfParams: baseParams,
            ldfState: bytes32(0)
        });

        assertEq(actualDensity, expectedDensity, "Density mismatch");
        assertEq(actualCumAmount0, expectedCumAmount0, "Cumulative amount 0 mismatch");
        assertEq(actualCumAmount1, expectedCumAmount1, "Cumulative amount 1 mismatch");
    }

    function test_ldfMatchesBaseDistributions_doubleGeometric_dynamic(
        int24 currentTick,
        int24 twapTick,
        int24 minTick,
        int24 length0,
        int24 length1,
        uint32 alpha0,
        uint32 alpha1,
        uint32 weight0,
        uint32 weight1,
        uint32 weightCarpet,
        uint8 shiftMode_
    ) public {
        shiftMode_ = uint8(bound(shiftMode_, 0, 2));
        ShiftMode shiftMode = ShiftMode(shiftMode_);

        int24 tickSpacing = TICK_SPACING;
        (int24 minUsableTick, int24 maxUsableTick) =
            (TickMath.minUsableTick(tickSpacing), TickMath.maxUsableTick(tickSpacing));
        minTick = roundTickSingle(int24(bound(minTick, minUsableTick, maxUsableTick - 3 * tickSpacing)), tickSpacing);

        weight0 = uint32(bound(weight0, 1, 1e6));
        weight1 = uint32(bound(weight1, 1, 1e6));

        alpha1 = uint32(bound(alpha1, MIN_ALPHA, MAX_ALPHA));
        vm.assume(alpha1 != 1e8); // 1e8 is a special case that causes overflow
        minTick = roundTickSingle(int24(bound(minTick, minUsableTick, maxUsableTick - 2 * tickSpacing)), tickSpacing);
        length1 = int24(bound(length1, 1, (maxUsableTick - minTick) / tickSpacing - 1));

        alpha0 = uint32(bound(alpha0, MIN_ALPHA, MAX_ALPHA));
        vm.assume(alpha0 != 1e8); // 1e8 is a special case that causes overflow
        length0 = int24(
            bound(
                length0,
                1,
                FixedPointMathLib.max(1, (maxUsableTick - (minTick + length1 * tickSpacing)) / tickSpacing - 1)
            )
        );

        weightCarpet = uint32(bound(weightCarpet, 1, type(uint32).max));

        currentTick = int24(bound(currentTick, minUsableTick, maxUsableTick));
        twapTick = int24(bound(twapTick, minUsableTick, maxUsableTick));
        int24 roundedTick = roundTickSingle(currentTick, tickSpacing);

        // deploy double geometric LDF
        ILiquidityDensityFunction doubleGeometricLdf =
            new CarpetedDoubleGeometricDistribution(address(hub), address(bunniHook), address(quoter));

        // construct params
        bytes28 baseParams = bytes28(
            abi.encodePacked(
                shiftMode,
                int24(minTick),
                int16(length0),
                uint32(alpha0),
                uint32(weight0),
                int16(length1),
                uint32(alpha1),
                uint32(weight1),
                uint32(weightCarpet)
            )
        );
        if (!doubleGeometricLdf.isValidParams(key, 15 minutes, baseParams, LDFType.DYNAMIC_AND_STATEFUL)) return;

        // set params
        curatedLdf.setLdfParams(key, DistributionType.CARPETED_DOUBLE_GEOMETRIC, baseParams);

        // query LDF
        vm.prank(address(hub));
        (uint256 actualDensity, uint256 actualCumAmount0, uint256 actualCumAmount1,,) = curatedLdf.query({
            key: key,
            roundedTick: roundedTick,
            twapTick: twapTick,
            spotPriceTick: currentTick,
            ldfParams: _createDefaultParams(),
            ldfState: bytes32(0)
        });

        // query base distribution
        vm.prank(address(hub));
        (uint256 expectedDensity, uint256 expectedCumAmount0, uint256 expectedCumAmount1,,) = doubleGeometricLdf.query({
            key: key,
            roundedTick: roundedTick,
            twapTick: twapTick,
            spotPriceTick: currentTick,
            ldfParams: baseParams,
            ldfState: bytes32(0)
        });

        assertEq(actualDensity, expectedDensity, "Density mismatch");
        assertEq(actualCumAmount0, expectedCumAmount0, "Cumulative amount 0 mismatch");
        assertEq(actualCumAmount1, expectedCumAmount1, "Cumulative amount 1 mismatch");
    }

    function test_ldfStateShouldClearAfterParamUpdate_uniform() public {
        // construct initial params
        // uniform with range [0, 10] and STATIC shift mode
        bytes28 baseParams = bytes28(abi.encodePacked(ShiftMode.STATIC, int24(0), int24(10)));

        // set new params
        curatedLdf.setLdfParams(key, DistributionType.UNIFORM, baseParams);

        // query LDF to get updated state
        vm.prank(address(hub));
        (,,, bytes32 state,) = curatedLdf.query({
            key: key,
            roundedTick: 0,
            twapTick: 0,
            spotPriceTick: 0,
            ldfParams: _createDefaultParams(),
            ldfState: bytes32(0)
        });

        // construct new params
        // uniform with range [-100, -90] and RIGHT shift mode
        bytes28 newBaseParams = bytes28(abi.encodePacked(ShiftMode.RIGHT, int24(-100), int24(1)));

        // set new params
        curatedLdf.setLdfParams(key, DistributionType.UNIFORM, newBaseParams);

        // query LDF
        vm.prank(address(hub));
        (uint256 liquidityDensityX96,,,,) = curatedLdf.query({
            key: key,
            roundedTick: int24(-100),
            twapTick: 0,
            spotPriceTick: int24(-100),
            ldfParams: _createDefaultParams(),
            ldfState: state
        });

        // liquidityDensity should equal Q96
        // liquidity should be in [-100, -90] even though it's to the left of the previous min tick 0 in STATIC mode
        assertEq(liquidityDensityX96, Q96, "Liquidity density mismatch");
    }

    function test_ldfStateShouldClearAfterParamUpdate_geometric() public {
        // construct initial params
        // geometric with min tick 0, length 1, alpha 1.2e8, and weight 1e6 and STATIC shift mode
        bytes28 baseParams = bytes28(abi.encodePacked(ShiftMode.STATIC, int24(0), int16(1), uint32(1.2e8), uint32(1e6)));

        // set new params
        curatedLdf.setLdfParams(key, DistributionType.CARPETED_GEOMETRIC, baseParams);

        // query LDF to get updated state
        vm.prank(address(hub));
        (,,, bytes32 state,) = curatedLdf.query({
            key: key,
            roundedTick: 0,
            twapTick: 0,
            spotPriceTick: 0,
            ldfParams: _createDefaultParams(),
            ldfState: bytes32(0)
        });

        // construct new params
        // geometric with min tick -100, length 1, alpha 1.2e8, and weight 1e6 and RIGHT shift mode
        bytes28 newBaseParams =
            bytes28(abi.encodePacked(ShiftMode.RIGHT, int24(-100), int16(1), uint32(1.2e8), uint32(1e6)));

        // set new params
        curatedLdf.setLdfParams(key, DistributionType.CARPETED_GEOMETRIC, newBaseParams);

        // query LDF
        vm.prank(address(hub));
        (uint256 liquidityDensityX96,,,,) = curatedLdf.query({
            key: key,
            roundedTick: int24(-100),
            twapTick: 0,
            spotPriceTick: int24(-100),
            ldfParams: _createDefaultParams(),
            ldfState: state
        });

        // liquidityDensity should equal Q96
        assertApproxEqRel(liquidityDensityX96, Q96, 1e6, "Liquidity density mismatch");
    }

    function test_ldfStateShouldClearAfterParamUpdate_doubleGeometric() public {
        // construct initial params
        // double geometric with min tick 0, length 2 and STATIC shift mode
        bytes28 baseParams = bytes28(
            abi.encodePacked(
                ShiftMode.STATIC,
                int24(0),
                int16(1),
                uint32(1.2e8),
                uint32(1e6),
                int16(1),
                uint32(1.2e8),
                uint32(1e6),
                uint32(1e6)
            )
        );

        // set new params
        curatedLdf.setLdfParams(key, DistributionType.CARPETED_DOUBLE_GEOMETRIC, baseParams);

        // query LDF to get updated state
        vm.prank(address(hub));
        (,,, bytes32 state,) = curatedLdf.query({
            key: key,
            roundedTick: 0,
            twapTick: 0,
            spotPriceTick: 0,
            ldfParams: _createDefaultParams(),
            ldfState: bytes32(0)
        });

        // construct new params
        // double geometric with min tick -100, length 1, alpha 1.2e8, and weight 1e6 and RIGHT shift mode
        bytes28 newBaseParams = bytes28(
            abi.encodePacked(
                ShiftMode.RIGHT,
                int24(-100),
                int16(1),
                uint32(1.2e8),
                uint32(1e6),
                int16(1),
                uint32(1.2e8),
                uint32(1e6),
                uint32(1e6)
            )
        );

        // set new params
        curatedLdf.setLdfParams(key, DistributionType.CARPETED_DOUBLE_GEOMETRIC, newBaseParams);

        // query LDF
        vm.prank(address(hub));
        (uint256 liquidityDensityX96,,,,) = curatedLdf.query({
            key: key,
            roundedTick: int24(-100),
            twapTick: 0,
            spotPriceTick: int24(-100),
            ldfParams: _createDefaultParams(),
            ldfState: state
        });

        // liquidityDensity should equal Q96 / 2
        assertApproxEqRel(liquidityDensityX96, Q96 / 2, 1e6, "Liquidity density mismatch");
    }

    function test_setLdfParams_onlyOwner() public {
        bytes4 selector = bytes4(0x82b42900); // Unauthorized() selector
        address nonOwner = address(0xdead);

        bytes28 baseParams = bytes28(abi.encodePacked(ShiftMode.STATIC, int24(0), int24(10)));

        // should revert for non-owner
        vm.prank(nonOwner);
        vm.expectRevert(selector); // Unauthorized()
        curatedLdf.setLdfParams(key, DistributionType.UNIFORM, baseParams);

        // should work for owner
        vm.prank(address(bunniToken.owner()));
        curatedLdf.setLdfParams(key, DistributionType.UNIFORM, baseParams);

        // should work after transferring ownership
        vm.prank(address(bunniToken.owner()));
        bunniToken.transferOwnership(nonOwner);
        vm.prank(nonOwner);
        curatedLdf.setLdfParams(key, DistributionType.UNIFORM, baseParams);
    }

    function test_setInvalidLdfParamsPoC() public {
        vm.startPrank(address(bunniToken.owner()));

        // set inital valid override
        curatedLdf.setLdfParams(
            key, DistributionType.UNIFORM, bytes28(abi.encodePacked(ShiftMode.STATIC, int24(0), int24(10)))
        );

        // now set an invalid override with ShiftMode outside the actual range, min tick of the max int24 and negative length
        vm.expectRevert("InvalidLdfParams()");
        curatedLdf.setLdfParams(
            key,
            DistributionType.UNIFORM,
            bytes28(abi.encodePacked(uint8(type(ShiftMode).max) + 42, type(int24).max, -int24(10)))
        );
    }

    function test_surgeOnParamsUpdatePoC() public {
        bytes32 ldfParams = _createDefaultParams();

        // query LDF to initialize state
        vm.prank(address(hub));
        (,,, bytes32 state, bool shouldSurge) = curatedLdf.query({
            key: key,
            roundedTick: 0,
            twapTick: 0,
            spotPriceTick: 0,
            ldfParams: ldfParams,
            ldfState: bytes32(0)
        });

        // should not surge on init
        assertFalse(shouldSurge, "Should not surge on init");

        // construct new params by modifying the unused base params bytes
        bytes28 newBaseParams =
            bytes28(abi.encodePacked(ShiftMode.STATIC, int24(-100), int24(200), bytes20(0), uint8(42)));

        // set new params
        curatedLdf.setLdfParams(key, DistributionType.UNIFORM, newBaseParams);

        // query LDF
        vm.prank(address(hub));
        (,,, state, shouldSurge) = curatedLdf.query({
            key: key,
            roundedTick: 0,
            twapTick: 0,
            spotPriceTick: 0,
            ldfParams: ldfParams,
            ldfState: state
        });

        assertFalse(shouldSurge, "Should not surge on params update if only unusued byte is updated");

        (DistributionType distroBefore, bytes28 baseParamsBefore) = curatedLdf.decodeLdfParams(ldfParams);
        bytes32 newLdfParams = bytes32(abi.encodePacked(newBaseParams, bytes3(0), DistributionType.UNIFORM));
        (DistributionType distroAfter, bytes28 baseParamsAfter) = curatedLdf.decodeLdfParams(newLdfParams);

        assertEq(
            curatedLdf.sanitizeBaseLdfParams(distroBefore, baseParamsBefore),
            curatedLdf.sanitizeBaseLdfParams(distroAfter, baseParamsAfter),
            "Base params (sanitized) should be equal before and after update"
        );

        (
            bool initializedBefore,
            int24 lastMinTickBefore,
            DistributionType lastDistributionTypeBefore,
            bytes28 lastBaseLdfParamsBefore
        ) = curatedLdf.decodeState(state);
        (
            bool initializedAfter,
            int24 lastMinTickAfter,
            DistributionType lastDistributionTypeAfter,
            bytes28 lastBaseLdfParamsAfter
        ) = curatedLdf.decodeState(state);

        assertEq(initializedBefore, initializedAfter, "Initialized state should not change");
        assertEq(lastMinTickBefore, lastMinTickAfter, "Last min tick should not change");
        assertEq(
            uint8(lastDistributionTypeBefore),
            uint8(lastDistributionTypeAfter),
            "Last distribution type should not change"
        );
        assertEq(lastBaseLdfParamsBefore, lastBaseLdfParamsAfter, "Last base LDF params should not change");
    }

    /// -----------------------------------------------------------------------
    /// Internal helpers
    /// -----------------------------------------------------------------------

    function _createDefaultParams() internal pure returns (bytes32) {
        // uniform distribution [-100, 200]
        // need the bytes24(0) to make distribution type the last byte
        return
            bytes32(abi.encodePacked(ShiftMode.STATIC, int24(-100), int24(200), bytes24(0), DistributionType.UNIFORM));
    }

    function _deployPoolAndInitLiquidity(ILiquidityDensityFunction ldf_, bytes32 ldfParams, bytes32 salt)
        internal
        returns (IBunniToken bunniToken, PoolKey memory key)
    {
        return _deployPoolAndInitLiquidity(
            Currency.wrap(address(token0)),
            Currency.wrap(address(token1)),
            ERC4626(address(0)),
            ERC4626(address(0)),
            ldf_,
            IHooklet(address(0)),
            ldfParams,
            abi.encodePacked(
                FEE_MIN,
                FEE_MAX,
                FEE_QUADRATIC_MULTIPLIER,
                FEE_TWAP_SECONDS_AGO,
                POOL_MAX_AMAMM_FEE,
                SURGE_HALFLIFE,
                SURGE_AUTOSTART_TIME,
                VAULT_SURGE_THRESHOLD_0,
                VAULT_SURGE_THRESHOLD_1,
                REBALANCE_THRESHOLD,
                REBALANCE_MAX_SLIPPAGE,
                REBALANCE_TWAP_SECONDS_AGO,
                REBALANCE_ORDER_TTL,
                true, // amAmmEnabled
                ORACLE_MIN_INTERVAL,
                MIN_RENT_MULTIPLIER
            ),
            salt
        );
    }
}
