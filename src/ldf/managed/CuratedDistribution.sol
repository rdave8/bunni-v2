// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import "../ShiftMode.sol";
import {Guarded} from "../../base/Guarded.sol";
import {LDFType} from "../../types/LDFType.sol";
import {PoolState} from "../../types/PoolState.sol";
import {IBunniHub} from "../../interfaces/IBunniHub.sol";
import {LibUniformDistribution} from "../LibUniformDistribution.sol";
import {LibGeometricDistribution} from "../LibGeometricDistribution.sol";
import {LibDoubleGeometricDistribution} from "../LibDoubleGeometricDistribution.sol";
import {ILiquidityDensityFunction} from "../../interfaces/ILiquidityDensityFunction.sol";
import {LibCarpetedGeometricDistribution} from "../LibCarpetedGeometricDistribution.sol";
import {LibCarpetedDoubleGeometricDistribution} from "../LibCarpetedDoubleGeometricDistribution.sol";

enum DistributionType {
    NULL, // exists so that if ldfParams is bytes32(0) we know it's not overridden
    UNIFORM,
    CARPETED_GEOMETRIC,
    CARPETED_DOUBLE_GEOMETRIC
}

/// @title CuratedDistribution
/// @author zefram.eth
/// @notice LDF managed by a curator who can switch between multiple basic LDFs & change LDF parameters
/// @dev The baseLdfParams of each base LDF cannot exceed 28 bytes. This is satisfied since the max
/// is 28 bytes which is used by the carpeted double geometric LDF.
contract CuratedDistribution is ILiquidityDensityFunction, Guarded {
    mapping(PoolId => bytes32) public ldfParamsOverride;

    bytes32 internal constant BASE_LDF_PARAMS_MASK = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff00;

    event SetLdfParamsOverride(
        PoolId indexed id, DistributionType indexed distributionType, bytes32 indexed baseLdfParams
    );

    error Unauthorized();
    error InvalidLdfParams();

    constructor(address hub_, address hook_, address quoter_) Guarded(hub_, hook_, quoter_) {}

    /// @inheritdoc ILiquidityDensityFunction
    function query(
        PoolKey calldata key,
        int24 roundedTick,
        int24 twapTick,
        int24 spotPriceTick,
        bytes32 ldfParams,
        bytes32 ldfState
    )
        external
        view
        override
        guarded
        returns (
            uint256 liquidityDensityX96_,
            uint256 cumulativeAmount0DensityX96,
            uint256 cumulativeAmount1DensityX96,
            bytes32 newLdfState,
            bool shouldSurge
        )
    {
        // override ldf params if needed
        PoolId id = key.toId();
        bytes32 ldfParamsOverride_ = ldfParamsOverride[id];
        ldfParams = ldfParamsOverride_ == bytes32(0) ? ldfParams : ldfParamsOverride_;

        // decode ldf params and check surge
        (DistributionType distro, bytes28 baseLdfParams) = _decodeLdfParams(ldfParams);
        (bool initialized, int24 lastMinTick, DistributionType lastDistributionType, bytes28 lastBaseLdfParams) =
            _decodeState(ldfState);
        if (initialized) {
            // should surge if param was updated
            // if param was updated, the ldfState should be cleared since state for the previous config
            // may affect the new config unnecessarily
            // for example, if the previous LDF was uniform with range [0, 10] and STATIC shift mode and the new
            // config is uniform with range [-100, -90] and RIGHT shift mode, if the state wasn't cleared then
            // the LDF will still be [0, 10] when it should really be [-100, -90].
            if (lastBaseLdfParams != baseLdfParams || lastDistributionType != distro) {
                shouldSurge = true;
                initialized = false; // this tells the later logic to ignore the state
            }
        }

        // compute results based on distribution type
        if (distro == DistributionType.UNIFORM) {
            (int24 tickLower, int24 tickUpper, ShiftMode shiftMode) =
                LibUniformDistribution.decodeParams(twapTick, key.tickSpacing, baseLdfParams);

            if (initialized) {
                (tickLower, tickUpper) =
                    _enforceUniformShiftMode(tickLower, tickUpper, shiftMode, lastMinTick, key.tickSpacing);
                shouldSurge = shouldSurge || tickLower != lastMinTick;
            }

            (liquidityDensityX96_, cumulativeAmount0DensityX96, cumulativeAmount1DensityX96) = LibUniformDistribution
                .query({roundedTick: roundedTick, tickSpacing: key.tickSpacing, tickLower: tickLower, tickUpper: tickUpper});

            // update ldf state
            newLdfState = _encodeState(tickLower, distro, baseLdfParams);
        } else if (distro == DistributionType.CARPETED_GEOMETRIC) {
            (int24 minTick, int24 length, uint256 alphaX96, uint256 weightCarpet, ShiftMode shiftMode) =
                LibCarpetedGeometricDistribution.decodeParams(twapTick, key.tickSpacing, baseLdfParams);
            if (initialized) {
                minTick = enforceShiftMode(minTick, lastMinTick, shiftMode);
                shouldSurge = shouldSurge || minTick != lastMinTick;
            }

            (liquidityDensityX96_, cumulativeAmount0DensityX96, cumulativeAmount1DensityX96) =
            LibCarpetedGeometricDistribution.query({
                roundedTick: roundedTick,
                tickSpacing: key.tickSpacing,
                minTick: minTick,
                length: length,
                alphaX96: alphaX96,
                weightCarpet: weightCarpet
            });

            // update ldf state
            newLdfState = _encodeState(minTick, distro, baseLdfParams);
        } else {
            LibCarpetedDoubleGeometricDistribution.Params memory params =
                LibCarpetedDoubleGeometricDistribution.decodeParams(twapTick, key.tickSpacing, baseLdfParams);
            if (initialized) {
                params.minTick = enforceShiftMode(params.minTick, lastMinTick, params.shiftMode);
                shouldSurge = shouldSurge || params.minTick != lastMinTick;
            }

            (liquidityDensityX96_, cumulativeAmount0DensityX96, cumulativeAmount1DensityX96) =
            LibCarpetedDoubleGeometricDistribution.query({
                roundedTick: roundedTick,
                tickSpacing: key.tickSpacing,
                params: params
            });

            // update ldf state
            newLdfState = _encodeState(params.minTick, distro, baseLdfParams);
        }
    }

    /// @inheritdoc ILiquidityDensityFunction
    function computeSwap(
        PoolKey calldata key,
        uint256 inverseCumulativeAmountInput,
        uint256 totalLiquidity,
        bool zeroForOne,
        bool exactIn,
        int24 twapTick,
        int24, /* spotPriceTick */
        bytes32 ldfParams,
        bytes32 ldfState
    )
        external
        view
        override
        guarded
        returns (
            bool success,
            int24 roundedTick,
            uint256 cumulativeAmount0_,
            uint256 cumulativeAmount1_,
            uint256 swapLiquidity
        )
    {
        // override ldf params if needed
        PoolId id = key.toId();
        bytes32 ldfParamsOverride_ = ldfParamsOverride[id];
        ldfParams = ldfParamsOverride_ == bytes32(0) ? ldfParams : ldfParamsOverride_;

        // decode ldf params
        (DistributionType distro, bytes28 baseLdfParams) = _decodeLdfParams(ldfParams);
        (bool initialized, int24 lastMinTick, DistributionType lastDistributionType, bytes28 lastBaseLdfParams) =
            _decodeState(ldfState);
        if (initialized) {
            // if param was updated, the ldfState should be cleared since state for the previous config
            // may affect the new config unnecessarily
            // for example, if the previous LDF was uniform with range [0, 10] and STATIC shift mode and the new
            // config is uniform with range [-100, -90] and RIGHT shift mode, if the state wasn't cleared then
            // the LDF will still be [0, 10] when it should really be [-100, -90].
            if (lastBaseLdfParams != baseLdfParams || lastDistributionType != distro) {
                initialized = false; // this tells the later logic to ignore the state
            }
        }

        if (distro == DistributionType.UNIFORM) {
            (int24 tickLower, int24 tickUpper, ShiftMode shiftMode) =
                LibUniformDistribution.decodeParams(twapTick, key.tickSpacing, baseLdfParams);

            if (initialized) {
                (tickLower, tickUpper) =
                    _enforceUniformShiftMode(tickLower, tickUpper, shiftMode, lastMinTick, key.tickSpacing);
            }

            return LibUniformDistribution.computeSwap({
                inverseCumulativeAmountInput: inverseCumulativeAmountInput,
                totalLiquidity: totalLiquidity,
                zeroForOne: zeroForOne,
                exactIn: exactIn,
                tickSpacing: key.tickSpacing,
                tickLower: tickLower,
                tickUpper: tickUpper
            });
        } else if (distro == DistributionType.CARPETED_GEOMETRIC) {
            (int24 minTick, int24 length, uint256 alphaX96, uint256 weightCarpet, ShiftMode shiftMode) =
                LibCarpetedGeometricDistribution.decodeParams(twapTick, key.tickSpacing, baseLdfParams);

            if (initialized) {
                minTick = enforceShiftMode(minTick, lastMinTick, shiftMode);
            }

            return LibCarpetedGeometricDistribution.computeSwap({
                inverseCumulativeAmountInput: inverseCumulativeAmountInput,
                totalLiquidity: totalLiquidity,
                zeroForOne: zeroForOne,
                exactIn: exactIn,
                tickSpacing: key.tickSpacing,
                minTick: minTick,
                length: length,
                alphaX96: alphaX96,
                weightCarpet: weightCarpet
            });
        } else {
            LibCarpetedDoubleGeometricDistribution.Params memory params =
                LibCarpetedDoubleGeometricDistribution.decodeParams(twapTick, key.tickSpacing, baseLdfParams);
            if (initialized) {
                params.minTick = enforceShiftMode(params.minTick, lastMinTick, params.shiftMode);
            }

            return LibCarpetedDoubleGeometricDistribution.computeSwap({
                inverseCumulativeAmountInput: inverseCumulativeAmountInput,
                totalLiquidity: totalLiquidity,
                zeroForOne: zeroForOne,
                exactIn: exactIn,
                tickSpacing: key.tickSpacing,
                params: params
            });
        }
    }

    /// @inheritdoc ILiquidityDensityFunction
    function cumulativeAmount0(
        PoolKey calldata key,
        int24 roundedTick,
        uint256 totalLiquidity,
        int24 twapTick,
        int24, /* spotPriceTick */
        bytes32 ldfParams,
        bytes32 ldfState
    ) external view override guarded returns (uint256) {
        // override ldf params if needed
        PoolId id = key.toId();
        bytes32 ldfParamsOverride_ = ldfParamsOverride[id];
        ldfParams = ldfParamsOverride_ == bytes32(0) ? ldfParams : ldfParamsOverride_;

        // decode ldf params
        (DistributionType distro, bytes28 baseLdfParams) = _decodeLdfParams(ldfParams);
        (bool initialized, int24 lastMinTick, DistributionType lastDistributionType, bytes28 lastBaseLdfParams) =
            _decodeState(ldfState);
        if (initialized) {
            // if param was updated, the ldfState should be cleared since state for the previous config
            // may affect the new config unnecessarily
            // for example, if the previous LDF was uniform with range [0, 10] and STATIC shift mode and the new
            // config is uniform with range [-100, -90] and RIGHT shift mode, if the state wasn't cleared then
            // the LDF will still be [0, 10] when it should really be [-100, -90].
            if (lastBaseLdfParams != baseLdfParams || lastDistributionType != distro) {
                initialized = false; // this tells the later logic to ignore the state
            }
        }

        if (distro == DistributionType.UNIFORM) {
            (int24 tickLower, int24 tickUpper, ShiftMode shiftMode) =
                LibUniformDistribution.decodeParams(twapTick, key.tickSpacing, baseLdfParams);

            if (initialized) {
                (tickLower, tickUpper) =
                    _enforceUniformShiftMode(tickLower, tickUpper, shiftMode, lastMinTick, key.tickSpacing);
            }

            return LibUniformDistribution.cumulativeAmount0(
                roundedTick, totalLiquidity, key.tickSpacing, tickLower, tickUpper, false
            );
        } else if (distro == DistributionType.CARPETED_GEOMETRIC) {
            (int24 minTick, int24 length, uint256 alphaX96, uint256 weightCarpet, ShiftMode shiftMode) =
                LibCarpetedGeometricDistribution.decodeParams(twapTick, key.tickSpacing, baseLdfParams);

            if (initialized) {
                minTick = enforceShiftMode(minTick, lastMinTick, shiftMode);
            }

            return LibCarpetedGeometricDistribution.cumulativeAmount0({
                roundedTick: roundedTick,
                totalLiquidity: totalLiquidity,
                tickSpacing: key.tickSpacing,
                minTick: minTick,
                length: length,
                alphaX96: alphaX96,
                weightCarpet: weightCarpet
            });
        } else {
            LibCarpetedDoubleGeometricDistribution.Params memory params =
                LibCarpetedDoubleGeometricDistribution.decodeParams(twapTick, key.tickSpacing, baseLdfParams);
            if (initialized) {
                params.minTick = enforceShiftMode(params.minTick, lastMinTick, params.shiftMode);
            }

            return LibCarpetedDoubleGeometricDistribution.cumulativeAmount0({
                roundedTick: roundedTick,
                totalLiquidity: totalLiquidity,
                tickSpacing: key.tickSpacing,
                params: params
            });
        }
    }

    /// @inheritdoc ILiquidityDensityFunction
    function cumulativeAmount1(
        PoolKey calldata key,
        int24 roundedTick,
        uint256 totalLiquidity,
        int24 twapTick,
        int24, /* spotPriceTick */
        bytes32 ldfParams,
        bytes32 ldfState
    ) external view override guarded returns (uint256) {
        // override ldf params if needed
        PoolId id = key.toId();
        bytes32 ldfParamsOverride_ = ldfParamsOverride[id];
        ldfParams = ldfParamsOverride_ == bytes32(0) ? ldfParams : ldfParamsOverride_;

        // decode ldf params
        (DistributionType distro, bytes28 baseLdfParams) = _decodeLdfParams(ldfParams);
        (bool initialized, int24 lastMinTick, DistributionType lastDistributionType, bytes28 lastBaseLdfParams) =
            _decodeState(ldfState);
        if (initialized) {
            // if param was updated, the ldfState should be cleared since state for the previous config
            // may affect the new config unnecessarily
            // for example, if the previous LDF was uniform with range [0, 10] and STATIC shift mode and the new
            // config is uniform with range [-100, -90] and RIGHT shift mode, if the state wasn't cleared then
            // the LDF will still be [0, 10] when it should really be [-100, -90].
            if (lastBaseLdfParams != baseLdfParams || lastDistributionType != distro) {
                initialized = false; // this tells the later logic to ignore the state
            }
        }

        if (distro == DistributionType.UNIFORM) {
            (int24 tickLower, int24 tickUpper, ShiftMode shiftMode) =
                LibUniformDistribution.decodeParams(twapTick, key.tickSpacing, baseLdfParams);

            if (initialized) {
                (tickLower, tickUpper) =
                    _enforceUniformShiftMode(tickLower, tickUpper, shiftMode, lastMinTick, key.tickSpacing);
            }

            return LibUniformDistribution.cumulativeAmount1(
                roundedTick, totalLiquidity, key.tickSpacing, tickLower, tickUpper, false
            );
        } else if (distro == DistributionType.CARPETED_GEOMETRIC) {
            (int24 minTick, int24 length, uint256 alphaX96, uint256 weightCarpet, ShiftMode shiftMode) =
                LibCarpetedGeometricDistribution.decodeParams(twapTick, key.tickSpacing, baseLdfParams);

            if (initialized) {
                minTick = enforceShiftMode(minTick, lastMinTick, shiftMode);
            }

            return LibCarpetedGeometricDistribution.cumulativeAmount1({
                roundedTick: roundedTick,
                totalLiquidity: totalLiquidity,
                tickSpacing: key.tickSpacing,
                minTick: minTick,
                length: length,
                alphaX96: alphaX96,
                weightCarpet: weightCarpet
            });
        } else {
            LibCarpetedDoubleGeometricDistribution.Params memory params =
                LibCarpetedDoubleGeometricDistribution.decodeParams(twapTick, key.tickSpacing, baseLdfParams);
            if (initialized) {
                params.minTick = enforceShiftMode(params.minTick, lastMinTick, params.shiftMode);
            }

            return LibCarpetedDoubleGeometricDistribution.cumulativeAmount1({
                roundedTick: roundedTick,
                totalLiquidity: totalLiquidity,
                tickSpacing: key.tickSpacing,
                params: params
            });
        }
    }

    /// @inheritdoc ILiquidityDensityFunction
    function isValidParams(PoolKey calldata key, uint24 twapSecondsAgo, bytes32 ldfParams, LDFType ldfType)
        public
        view
        override
        returns (bool)
    {
        // ldfType needs to be DYNAMIC_AND_STATEFUL since we use ldfState to surge if params are updated
        if (ldfType != LDFType.DYNAMIC_AND_STATEFUL) {
            return false;
        }

        // decode ldf params
        // distribution type is always the last byte of ldfParams
        // | baseLdfParams - 31 bytes | distributionType - 1 byte |
        uint8 distributionTypeRaw = uint8(bytes1(ldfParams << 248));
        if (distributionTypeRaw == 0 || distributionTypeRaw > uint8(type(DistributionType).max)) {
            // invalid distribution type
            // can't be NULL or beyond max
            return false;
        }
        DistributionType distro = DistributionType(distributionTypeRaw);
        bytes32 baseLdfParams = ldfParams & BASE_LDF_PARAMS_MASK;
        uint8 shiftMode = uint8(bytes1(baseLdfParams)); // Use uint8 since we don't know if the value is in range yet. Due to the params format the first byte is always the shift mode.
        ldfType = shiftMode == uint8(ShiftMode.STATIC) ? LDFType.STATIC : LDFType.DYNAMIC_AND_STATEFUL; // need to fake ldfType to pass the base LDF checks since we always use DYNAMIC_AND_STATEFUL

        if (distro == DistributionType.UNIFORM) {
            return LibUniformDistribution.isValidParams({
                tickSpacing: key.tickSpacing,
                twapSecondsAgo: twapSecondsAgo,
                ldfParams: baseLdfParams,
                ldfType: ldfType
            });
        } else if (distro == DistributionType.CARPETED_GEOMETRIC) {
            return LibCarpetedGeometricDistribution.isValidParams({
                tickSpacing: key.tickSpacing,
                twapSecondsAgo: twapSecondsAgo,
                ldfParams: baseLdfParams,
                ldfType: ldfType
            });
        } else {
            return LibCarpetedDoubleGeometricDistribution.isValidParams({
                tickSpacing: key.tickSpacing,
                twapSecondsAgo: twapSecondsAgo,
                ldfParams: baseLdfParams,
                ldfType: ldfType
            });
        }
    }

    /// @notice Sets the ldf params for the given pool. Only callable by the owner.
    /// @param key The PoolKey of the Uniswap v4 pool
    /// @param distributionType The distribution type specifying the base LDF (e.g. Geometric)
    /// @param baseLdfParams The ldf params of the base LDF. Limited to bytes28 since that's the max supported size.
    function setLdfParams(PoolKey calldata key, DistributionType distributionType, bytes28 baseLdfParams) public {
        // can only be called by BunniToken owner
        PoolId id = key.toId();
        IBunniHub hub_ = IBunniHub(hub);
        if (msg.sender != hub_.bunniTokenOfPool(id).owner()) {
            revert Unauthorized();
        }

        // fetch Bunni pool state so we have access to twapSecondsAgo
        PoolState memory state = hub_.poolState(id);

        // ensure new params are valid
        // no need to check for ldfType since we always use DYNAMIC_AND_STATEFUL on init
        // distributionType is the last byte of ldfParams
        bytes32 ldfParams = bytes32(abi.encodePacked(baseLdfParams, bytes3(0), distributionType));
        bool isValid = isValidParams({
            key: key,
            twapSecondsAgo: state.twapSecondsAgo,
            ldfParams: ldfParams,
            ldfType: LDFType.DYNAMIC_AND_STATEFUL
        });
        if (!isValid) {
            revert InvalidLdfParams();
        }

        // override ldf params
        ldfParamsOverride[id] = ldfParams;
        emit SetLdfParamsOverride(id, distributionType, baseLdfParams);
    }

    function _decodeLdfParams(bytes32 ldfParams)
        internal
        pure
        returns (DistributionType distributionType, bytes28 baseLdfParams)
    {
        // | baseLdfParams - 31 bytes | distributionType - 1 byte |
        distributionType = DistributionType(uint8(bytes1(ldfParams << 248)));
        baseLdfParams = bytes28(ldfParams & BASE_LDF_PARAMS_MASK);
    }

    function _decodeState(bytes32 ldfState)
        internal
        pure
        returns (bool initialized, int24 lastMinTick, DistributionType lastDistributionType, bytes28 lastBaseLdfParams)
    {
        // | lastDistributionType - 1 byte | lastMinTick - 3 bytes | lastBaseLdfParams - 28 bytes |
        lastDistributionType = DistributionType(uint8(bytes1(ldfState)));
        lastMinTick = int24(uint24(bytes3(ldfState << 8)));
        lastBaseLdfParams = bytes28(ldfState << 32);
        initialized = lastDistributionType != DistributionType.NULL;
    }

    function _encodeState(int24 lastTwapTick, DistributionType lastDistributionType, bytes28 lastBaseLdfParams)
        internal
        pure
        returns (bytes32 ldfState)
    {
        // | lastDistributionType - 1 byte | lastTwapTick - 3 bytes | lastBaseLdfParams - 28 bytes |
        ldfState = bytes32(abi.encodePacked(lastDistributionType, lastTwapTick, lastBaseLdfParams));
    }

    function _enforceUniformShiftMode(
        int24 tickLower,
        int24 tickUpper,
        ShiftMode shiftMode,
        int24 lastMinTick,
        int24 tickSpacing
    ) internal pure returns (int24 tickLowerEnforced, int24 tickUpperEnforced) {
        int24 tickLength = tickUpper - tickLower;
        (int24 minUsableTick, int24 maxUsableTick) =
            (TickMath.minUsableTick(tickSpacing), TickMath.maxUsableTick(tickSpacing));
        tickLowerEnforced =
            int24(FixedPointMathLib.max(minUsableTick, enforceShiftMode(tickLower, lastMinTick, shiftMode)));
        tickUpperEnforced = int24(FixedPointMathLib.min(maxUsableTick, tickLowerEnforced + tickLength));
    }
}
