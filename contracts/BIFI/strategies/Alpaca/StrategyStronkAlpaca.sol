// SPDX-License-Identifier: MIT

pragma solidity ^0.6.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

import "../../interfaces/common/IUniswapRouterETH.sol";
import "../../interfaces/common/IUniswapV2Pair.sol";
import "../../interfaces/alpaca/IFairLaunch.sol";
import "../../utils/GasThrottler.sol";

/**
 * @dev Implementation of a strategy to get yields from farming with sALPACA.
 *
 * This strategy simply deposits whatever funds it receives from the vault into the selected FairLaunch pool.
 * ALPACA rewards from providing liquidity are farmed every few hours, sold and used to buy more sALPACA. 
 * 
 */
contract StrategyStronkAlpaca is Ownable, Pausable, GasThrottler {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    /**
     * @dev Tokens Used:
     * {wbnb} - Required for liquidity routing when doing swaps.
     * {bifi} - BeefyFinance token, used to send funds to the treasury.
     * {alpaca} - Token generated by staking our funds. In this case it's the ALPACA token.
     * {sAlpaca} - Token that the strategy maximizes. The same token that users deposit in the vault.
     */
    address constant public wbnb = address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    address constant public bifi = address(0xCa3F508B8e4Dd382eE878A314789373D80A5190A);
    address constant public alpaca = address(0x8F0528cE5eF7B51152A59745bEfDD91D97091d2F);
    address constant public sAlpaca = address(0x6F695Bd5FFD25149176629f8491A5099426Ce7a7);

    /**
     * @dev Third Party Contracts:
     * {unirouter} - PancakeSwap unirouter
     * {fairLaunch} - Alpaca FairLaunch contract
     * {poolId} - FairLaunch pool id for {sAlpaca}
     */
    address constant public unirouter  = address(0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F);
    address constant public fairLaunch = address(0xA625AB01B08ce023B2a342Dbb12a16f2C8489A8F);
    uint8 public poolId = 5;

    /**
     * @dev Beefy Contracts:
     * {rewards} - Reward pool where the strategy fee earnings will go.
     * {treasury} - Address of the BeefyFinance treasury
     * {vault} - Address of the vault that controls the strategy's funds.
     * {strategist} - Address of the strategy author/deployer where strategist fee will go.
     * {keeper} - Address used as an extra strat manager. 
     */
    address constant public rewards  = address(0x453D4Ba9a2D594314DF88564248497F7D74d6b2C);
    address constant public treasury = address(0x4A32De8c248533C28904b24B4cFCFE18E9F2ad01);
    address public vault;
    address public strategist;
    address public keeper;

    /**
     * @dev Distribution of fees earned. This allocations relative to the % implemented on doSplit().
     * Current implementation separates 4.5% for fees.
     *
     * {TREASURY_FEE} - 0.5% goes to the treasury.
     * {STRATEGIST_FEE} - 0.5% goes to the strategist.
     * {callFee} - 0.5% goes to whoever executes the harvest. Can be lowered.
     * {rewardsFee} - 3% that goes to BIFI holders. Can be increased by decreasing {callFee}.
     * {MAX_FEE} - Aux const used to safely calc the correct amounts.
     * {MAX_CALL_FEE} - Max value that the {callFee} can be configured to. 
     *
     * {WITHDRAWAL_FEE} - Fee taxed when a user withdraws funds. 10 === 0.1% fee.
     * {WITHDRAWAL_MAX} - Aux const used to safely calc the correct amounts.
     */
    uint constant public TREASURY_FEE   = 112;
    uint constant public STRATEGIST_FEE = 112;
    uint public callFee = 111;
    uint public rewardsFee = MAX_FEE - TREASURY_FEE - STRATEGIST_FEE - callFee;
    uint constant public MAX_FEE = 1000;
    uint constant public MAX_CALL_FEE = 111;

    uint constant public WITHDRAWAL_FEE = 10;
    uint constant public WITHDRAWAL_MAX = 10000;

    /**
     * @dev Routes we take to swap tokens using PancakeSwap.
     * {alpacaToWbnbRoute} - Route we take to get from {alpaca} into {wbnb}.
     * {wbnbToBifiRoute} - Route we take to get from {wbnb} into {bifi}.
     * {alpacaToSalpacaRoute} - Route we take to get from {alpaca} into {sAlpaca}.
     */
    address[] public alpacaToWbnbRoute = [alpaca, wbnb];
    address[] public wbnbToBifiRoute = [wbnb, bifi];
    address[] public alpacaToSalpacaRoute = [alpaca, sAlpaca];

    /**
     * @dev Event that is fired each time someone harvests the strat.
     */
    event StratHarvest();

    /**
     * @dev Initializes the strategy with the token to maximize.
     */
    constructor(address _vault, address _strategist) public {
        vault = _vault;
        strategist = _strategist;

        IERC20(sAlpaca).safeApprove(fairLaunch, uint(-1));
        IERC20(alpaca).safeApprove(unirouter, uint(-1));
        IERC20(wbnb).safeApprove(unirouter, uint(-1));
    }

    /**
     * @dev Function that puts the funds to work.
     * It gets called whenever someone deposits in the strategy's vault contract.
     * It deposits {sAlpaca} in the FairLaunch to farm {alpaca}
     */
    function deposit() public whenNotPaused {
        uint256 sAlpacaBal = IERC20(sAlpaca).balanceOf(address(this));

        if (sAlpacaBal > 0) {
            IFairLaunch(fairLaunch).deposit(address(this), poolId, sAlpacaBal);
        }
    }

    /**
     * @dev Withdraws funds and sends them back to the vault.
     * It withdraws {sAlpaca} from the FairLaunch.
     * The available {sAlpaca} minus fees is returned to the vault.
     */
    function withdraw(uint256 _amount) external {
        require(msg.sender == vault, "!vault");

        uint256 sAlpacaBal = IERC20(sAlpaca).balanceOf(address(this));

        if (sAlpacaBal < _amount) {
            IFairLaunch(fairLaunch).withdraw(address(this), poolId, _amount.sub(sAlpacaBal));
            sAlpacaBal = IERC20(sAlpaca).balanceOf(address(this));
        }

        if (sAlpacaBal > _amount) {
            sAlpacaBal = _amount;
        }

        if (tx.origin == owner() || paused()) {
            IERC20(sAlpaca).safeTransfer(vault, sAlpacaBal);
        } else {
            uint256 withdrawalFee = sAlpacaBal.mul(WITHDRAWAL_FEE).div(WITHDRAWAL_MAX);
            IERC20(sAlpaca).safeTransfer(vault, sAlpacaBal.sub(withdrawalFee));
        }
    }

    /**
     * @dev Public harvest. Doesn't work when the strat is paused.
     */
    function harvest() external whenNotPaused {
        _harvest();
    }

    /**
     * @dev Harvest to keep the strat working while paused. Helpful in some cases.
     */
    function sudoHarvest() external {
        require(msg.sender == owner() || msg.sender == keeper, "!authorized");

        _harvest();
    }

    /**
     * @dev Core function of the strat, in charge of collecting and re-investing rewards.
     * 1. It claims rewards from the FairLaunch.
     * 2. It charges the system fees to simplify the split.
     * 3. It swaps the {alpaca} token for more {sAlpaca}
     * 4. Deposits {sAlpaca} into the FairLaunch again.
     */
    function _harvest() internal gasThrottle {
        IFairLaunch(fairLaunch).harvest(poolId);
        chargeFees();
        swapRewards();
        deposit();

        emit StratHarvest();
    }

    /**
     * @dev Takes out 4.5% as system fees from the rewards. 
     * 0.5% -> Call Fee
     * 0.5% -> Treasury fee
     * 0.5% -> Strategist fee
     * 3.0% -> BIFI Holders
     */
    function chargeFees() internal {
        uint256 toWbnb = IERC20(alpaca).balanceOf(address(this)).mul(45).div(1000);
        IUniswapRouterETH(unirouter).swapExactTokensForTokens(toWbnb, 0, alpacaToWbnbRoute, address(this), now.add(600));

        uint256 wbnbBal = IERC20(wbnb).balanceOf(address(this));

        uint256 callFeeAmount = wbnbBal.mul(callFee).div(MAX_FEE);
        IERC20(wbnb).safeTransfer(msg.sender, callFeeAmount);

        uint256 treasuryHalf = wbnbBal.mul(TREASURY_FEE).div(MAX_FEE).div(2);
        IERC20(wbnb).safeTransfer(treasury, treasuryHalf);
        IUniswapRouterETH(unirouter).swapExactTokensForTokens(treasuryHalf, 0, wbnbToBifiRoute, treasury, now.add(600));

        uint256 rewardsFeeAmount = wbnbBal.mul(rewardsFee).div(MAX_FEE);
        IERC20(wbnb).safeTransfer(rewards, rewardsFeeAmount);

        uint256 strategistFee = wbnbBal.mul(STRATEGIST_FEE).div(MAX_FEE);
        IERC20(wbnb).safeTransfer(strategist, strategistFee);
    }

    /**
     * @dev Swaps whatever {alpaca} it has for more {sAlpaca}.
     */
    function swapRewards() internal {
        uint256 alpacaBal = IERC20(alpaca).balanceOf(address(this));
        IUniswapRouterETH(unirouter).swapExactTokensForTokens(alpacaBal, 0, alpacaToSalpacaRoute, address(this), now.add(600));
    }

    /**
     * @dev Function to calculate the total underlaying {sAlpaca} held by the strat.
     * It takes into account both the funds in hand, as the funds allocated in the FairLaunch.
     */
    function balanceOf() public view returns (uint256) {
        return balanceOfStrat().add(balanceOfPool());
    }

    /**
     * @dev It calculates how much {sAlpaca} the contract holds.
     */
    function balanceOfStrat() public view returns (uint256) {
        return IERC20(sAlpaca).balanceOf(address(this));
    }

    /**
     * @dev It calculates how much {sAlpaca} the strategy has allocated in the FairLaunch
     */
    function balanceOfPool() public view returns (uint256) {
        (uint256 _amount, ) = IFairLaunch(fairLaunch).userInfo(poolId, address(this));
        return _amount;
    }

    /**
     * @dev Function that has to be called as part of strat migration. It sends all the available funds back to the 
     * vault, ready to be migrated to the new strat.
     */
    function retireStrat() external {
        require(msg.sender == vault, "!vault");

        IFairLaunch(fairLaunch).emergencyWithdraw(poolId);

        uint256 sAlpacaBal = IERC20(sAlpaca).balanceOf(address(this));
        IERC20(sAlpaca).safeTransfer(vault, sAlpacaBal);
    }

    /**
     * @dev Pauses deposits. Withdraws all funds from the FairLaunch, leaving rewards behind
     */
    function panic() public {
        require(msg.sender == owner() || msg.sender == keeper, "!authorized");

        pause();
        IFairLaunch(fairLaunch).emergencyWithdraw(poolId);
    }

    /**
     * @dev Pauses the strat.
     */
    function pause() public {
        require(msg.sender == owner() || msg.sender == keeper, "!authorized");

        _pause();

        IERC20(sAlpaca).safeApprove(fairLaunch, 0);
        IERC20(alpaca).safeApprove(unirouter, 0);
        IERC20(wbnb).safeApprove(unirouter, 0);
    }

    /**
     * @dev Unpauses the strat.
     */
    function unpause() external {
        require(msg.sender == owner() || msg.sender == keeper, "!authorized");

        _unpause();

        IERC20(sAlpaca).safeApprove(fairLaunch, uint(-1));
        IERC20(alpaca).safeApprove(unirouter, uint(-1));
        IERC20(wbnb).safeApprove(unirouter, uint(-1));
    }

    /**
     * @dev Updates address where strategist fee earnings will go.
     * @param _strategist new strategist address.
     */
    function setStrategist(address _strategist) external {
        require(msg.sender == strategist, "!strategist");
        strategist = _strategist;
    }

    /**
     * @dev Updates address of the strat keeper.
     * @param _keeper new keeper address.
     */
    function setKeeper(address _keeper) external {
        require(msg.sender == owner() || msg.sender == keeper, "!authorized");
        
        keeper = _keeper;
    }

    /**
     * @dev Updates the harvest {callFee}. Capped by {MAX_CALL_FEE}.
     * @param _fee new fee to give harvesters. 
     */
    function setCallFee(uint256 _fee) external {
        require(msg.sender == owner() || msg.sender == keeper, "!authorized");
        require(_fee < MAX_CALL_FEE, "!cap");
        
        callFee = _fee;
        rewardsFee = MAX_FEE - TREASURY_FEE - STRATEGIST_FEE - callFee;
    }

    /**
     * @dev Rescues random funds stuck that the strat can't handle.
     * @param _token address oof the tkoen to rescue.
     */
    function inCaseTokensGetStuck(address _token) external {
        require(msg.sender == owner() || msg.sender == keeper, "!authorized");

        require(_token != wbnb, "!wbnb");
        require(_token != bifi, "!bifi");
        require(_token != alpaca, "!alpaca");
        require(_token != sAlpaca, "!sAlpaca");

        uint256 amount = IERC20(_token).balanceOf(address(this));
        IERC20(_token).safeTransfer(msg.sender, amount);
    }
}
