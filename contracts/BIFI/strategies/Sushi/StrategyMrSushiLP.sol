// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.6.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

import "../../interfaces/common/IUniswapRouterETH.sol";
import "../../interfaces/common/IUniswapV2Pair.sol";
import "../../interfaces/sushi/IMiniChefV2.sol";
import "../../interfaces/sushi/IRewarder.sol";
import "../../interfaces/common/IWrappedNative.sol";
import "../Common/StratManager.sol";
import "../Common/FeeManager.sol";

contract StrategyMrSushiLP is StratManager, FeeManager {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    address constant nullAddress = address(0);

    // Tokens used
    address public solarNative = address(0x98878B06940aE243284CA214f92Bb71a2b032B8A);
    address public sushiNative;
    address public output;
    address public want;
    address public lpToken0;
    address public lpToken1;

    // Third party contracts
    address public chef;
    address public unirouter2; // needed for wrapping native due to different wnative being used for performance fees
    uint256 public poolId;

    uint256 public lastHarvest;
    bool public harvestOnDeposit;

    // Routes
    address[] public outputToSushiNativeRoute;
    address[] public sushiNativeToLp0Route;
    address[] public sushiNativeToLp1Route;

    /**
     * @dev Event that is fired each time someone harvests the strat.
     */
    event StratHarvest(address indexed harvester, uint256 wantHarvested, uint256 tvl);
    event Deposit(uint256 tvl);
    event Withdraw(uint256 tvl);

    constructor(
        address _want,
        uint256 _poolId,
        address _chef,
        address _vault,
        address _unirouter,
        address _keeper,
        address _strategist,
        address _beefyFeeRecipient,
        address[] memory _outputToSushiNativeRoute,
        address[] memory _sushiNativeToLp0Route,
        address[] memory _sushiNativeToLp1Route
    ) StratManager(_keeper, _strategist, _unirouter, _vault, _beefyFeeRecipient) public {
        want = _want;
        poolId = _poolId;
        chef = _chef;

        require(_outputToSushiNativeRoute.length >= 2);
        output = _outputToSushiNativeRoute[0];
        sushiNative = _outputToSushiNativeRoute[_outputToSushiNativeRoute.length - 1];
        outputToSushiNativeRoute = _outputToSushiNativeRoute;

        // setup lp routing
        lpToken0 = IUniswapV2Pair(want).token0();
        require(_sushiNativeToLp0Route[0] == output);
        require(_sushiNativeToLp0Route[_sushiNativeToLp0Route.length - 1] == lpToken0);
        sushiNativeToLp0Route = _sushiNativeToLp0Route;

        lpToken1 = IUniswapV2Pair(want).token1();
        require(_sushiNativeToLp1Route[0] == output);
        require(_sushiNativeToLp1Route[_sushiNativeToLp1Route.length - 1] == lpToken1);
        sushiNativeToLp1Route = _sushiNativeToLp1Route;

        _giveAllowances();
    }

    // puts the funds to work
    function deposit() public whenNotPaused {
        uint256 wantBal = IERC20(want).balanceOf(address(this));

        if (wantBal > 0) {
            IMiniChefV2(chef).deposit(poolId, wantBal, address(this));
            emit Deposit(balanceOf());
        }
    }

    function withdraw(uint256 _amount) external {
        require(msg.sender == vault, "!vault");

        uint256 wantBal = IERC20(want).balanceOf(address(this));

        if (wantBal < _amount) {
            IMiniChefV2(chef).withdraw(poolId, _amount.sub(wantBal), address(this));
            wantBal = IERC20(want).balanceOf(address(this));
        }

        if (wantBal > _amount) {
            wantBal = _amount;
        }

        if (tx.origin != owner() && !paused()) {
            uint256 withdrawalFeeAmount = wantBal.mul(withdrawalFee).div(WITHDRAWAL_MAX);
            wantBal = wantBal.sub(withdrawalFeeAmount);
        }

        IERC20(want).safeTransfer(vault, wantBal);

        emit Withdraw(balanceOf());
    }

    function beforeDeposit() external override {
        if (harvestOnDeposit) {
            require(msg.sender == vault, "!vault");
            _harvest(tx.origin);
        }
    }

    function harvest() external virtual {
        _harvest(tx.origin);
    }

    function harvestWithCallFeeRecipient(address callFeeRecipient) external virtual {
        _harvest(callFeeRecipient);
    }

    function managerHarvest() external onlyManager {
        _harvest(tx.origin);
    }

    // compounds earnings and charges performance fee
    function _harvest(address callFeeRecipient) internal whenNotPaused {
        IMiniChefV2(chef).harvest(poolId, address(this));
        uint256 outputBal = IERC20(output).balanceOf(address(this));
        uint256 sushiNativeBal = IERC20(sushiNative).balanceOf(address(this));
        if (outputBal > 0 || sushiNativeBal > 0) {
            chargeFees(callFeeRecipient);
            addLiquidity();
            uint256 wantHarvested = balanceOfWant();
            deposit();
            lastHarvest = block.timestamp;
            emit StratHarvest(msg.sender, wantHarvested, balanceOf());
        }
    }

    // performance fees
    function chargeFees(address callFeeRecipient) internal {
        // rewards are in sushi and sushiNative, convert all to sushiNative 
        uint256 toSushiNative = IERC20(output).balanceOf(address(this));
        if (toSushiNative > 0) {
            IUniswapRouterETH(unirouter).swapExactTokensForTokens(toSushiNative, 0, outputToSushiNativeRoute, address(this), block.timestamp);
        }

        // unwrap fees in sushiNative to native gas
        IWrappedNative(sushiNative).withdraw(IERC20(sushiNative).balanceOf(address(this)).mul(45).div(1000));
        // wrap fees to solarNative
        IWrappedNative(solarNative).deposit{value: address(this).balance}();

        uint256 solarNativeBal = IERC20(solarNative).balanceOf(address(this));

        uint256 callFeeAmount = solarNativeBal.mul(callFee).div(MAX_FEE);
        IERC20(solarNative).safeTransfer(callFeeRecipient, callFeeAmount);

        uint256 beefyFeeAmount = solarNativeBal.mul(beefyFee).div(MAX_FEE);
        IERC20(solarNative).safeTransfer(beefyFeeRecipient, beefyFeeAmount);

        uint256 strategistFee = solarNativeBal.mul(STRATEGIST_FEE).div(MAX_FEE);
        IERC20(solarNative).safeTransfer(strategist, strategistFee);
    }

    // Adds liquidity to AMM and gets more LP tokens.
    function addLiquidity() internal {
        uint256 sushiNativeHalf = IERC20(sushiNative).balanceOf(address(this)).div(2);

        if (lpToken0 != sushiNative) {
            IUniswapRouterETH(unirouter).swapExactTokensForTokens(sushiNativeHalf, 0, sushiNativeToLp0Route, address(this), block.timestamp);
        }

        if (lpToken1 != sushiNative) {
            IUniswapRouterETH(unirouter).swapExactTokensForTokens(sushiNativeHalf, 0, sushiNativeToLp1Route, address(this), block.timestamp);
        }

        uint256 lp0Bal = IERC20(lpToken0).balanceOf(address(this));
        uint256 lp1Bal = IERC20(lpToken1).balanceOf(address(this));
        IUniswapRouterETH(unirouter).addLiquidity(lpToken0, lpToken1, lp0Bal, lp1Bal, 1, 1, address(this), block.timestamp);
    }

    // calculate the total underlaying 'want' held by the strat.
    function balanceOf() public view returns (uint256) {
        return balanceOfWant().add(balanceOfPool());
    }

    // it calculates how much 'want' this contract holds.
    function balanceOfWant() public view returns (uint256) {
        return IERC20(want).balanceOf(address(this));
    }

    // it calculates how much 'want' the strategy has working in the farm.
    function balanceOfPool() public view returns (uint256) {
        (uint256 _amount, ) = IMiniChefV2(chef).userInfo(poolId, address(this));
        return _amount;
    }

    // called as part of strat migration. Sends all the available funds back to the vault.
    function retireStrat() external {
        require(msg.sender == vault, "!vault");

        IMiniChefV2(chef).emergencyWithdraw(poolId, address(this));

        uint256 wantBal = IERC20(want).balanceOf(address(this));
        IERC20(want).transfer(vault, wantBal);
    }

    // returns rewards unharvested
    function rewardsAvailable() public view returns (uint256) {
        return IMiniChefV2(chef).pendingSushi(poolId, address(this));
    }

    // native reward amount for calling harvest
    function callReward() public view returns (uint256) {
        uint256 outputBal = rewardsAvailable();
        uint256 nativeOut;
         if (outputBal > 0) {
            try IUniswapRouterETH(unirouter).getAmountsOut(outputBal, outputToSushiNativeRoute)
                returns (uint256[] memory amountOut) 
            {
                nativeOut = amountOut[amountOut.length -1];
            }
            catch {}
        }

        uint256 pendingNative;
        address rewarder = IMiniChefV2(chef).rewarder(poolId);
        if (rewarder != nullAddress) {
            pendingNative = IRewarder(rewarder).pendingToken(poolId, address(this));
        }

        return pendingNative.add(nativeOut).mul(45).div(1000).mul(callFee).div(MAX_FEE);
    }

    function setHarvestOnDeposit(bool _harvestOnDeposit) external onlyManager {
        harvestOnDeposit = _harvestOnDeposit;

        if (harvestOnDeposit) {
            setWithdrawalFee(0);
        } else {
            setWithdrawalFee(10);
        }
    }

    // pauses deposits and withdraws all funds from third party systems.
    function panic() public onlyManager {
        pause();
        IMiniChefV2(chef).emergencyWithdraw(poolId, address(this));
    }

    function pause() public onlyManager {
        _pause();

        _removeAllowances();
    }

    function unpause() external onlyManager {
        _unpause();

        _giveAllowances();

        deposit();
    }

    function _giveAllowances() internal {
        IERC20(want).safeApprove(chef, type(uint256).max);
        IERC20(output).safeApprove(unirouter, type(uint256).max);
        IERC20(sushiNative).safeApprove(unirouter, type(uint256).max);

        IERC20(lpToken0).safeApprove(unirouter, 0);
        IERC20(lpToken0).safeApprove(unirouter, type(uint256).max);

        IERC20(lpToken1).safeApprove(unirouter, 0);
        IERC20(lpToken1).safeApprove(unirouter, type(uint256).max);
    }

    function _removeAllowances() internal {
        IERC20(want).safeApprove(chef, 0);
        IERC20(output).safeApprove(unirouter, 0);
        IERC20(sushiNative).safeApprove(unirouter, 0);
        IERC20(lpToken0).safeApprove(unirouter, 0);
        IERC20(lpToken1).safeApprove(unirouter, 0);
    }

    function outputToNative() external view returns (address[] memory) {
        return outputToSushiNativeRoute;
    }

    function sushiNativeToLp0() external view returns (address[] memory) {
        return sushiNativeToLp0Route;
    }

    function sushiNativeToLp1() external view returns (address[] memory) {
        return sushiNativeToLp1Route;
    }
}
