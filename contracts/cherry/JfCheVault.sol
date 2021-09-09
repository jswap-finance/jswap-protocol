pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/EnumerableSet.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "../interface/IJswapFactory.sol";
import "../interface/IJswapRouter.sol";
import "../interface/IJswapPair.sol";

contract JfCheVault is Ownable {
    using SafeERC20 for IERC20;
    using SafeMath for uint;

    IJswapFactory public jfFactory;
    IJswapFactory public cheFactory;

    IJswapRouter public jfRouter;
    IJswapRouter public cheRouter;
    
    address public jfToken;
    address public cheToken;
    //USDT
    address public bridgeToken;

    constructor(address _jfFactory, address _cheFactory, address _jfRouter, address _cheRouter, address _jfToken, address _cheToken, address _bridgeToken) public {
        jfFactory = IJswapFactory(_jfFactory);
        cheFactory = IJswapFactory(_cheFactory);

        jfRouter = IJswapRouter(_jfRouter);
        cheRouter = IJswapRouter(_cheRouter);

        jfToken = _jfToken;
        cheToken = _cheToken;
        bridgeToken = _bridgeToken;
    }

    function che2Jf(uint256 cheAmount) public view returns (uint256 jfAmount) {
        uint256 priceChe = price12(cheFactory, cheToken, bridgeToken);
        uint256 amountInternal = cheAmount.mul(priceChe).div(1e12);

        uint256 priceBridge = price12(jfFactory, bridgeToken, jfToken);

        jfAmount = priceBridge.mul(amountInternal).div(1e12);
    }
    // @dev price has be cale 1e12
    function price12(IJswapFactory _factory, address _bidToken, address _baseToken) public view returns(uint256) {

        IJswapPair pair = IJswapPair(_factory.getPair(_bidToken, _baseToken));
        require(address(pair) != address(0), 'JfCheValut: pair not exist');

        (uint256 rBid, uint256 rBased, ) = pair.getReserves();
        if(_bidToken > _baseToken) { // Reverse
            (rBid, rBased) = (rBased, rBid);
        }
        return rBased.mul(1e12).div(rBid);
    }

    //@notice approve then tansfer in one transaction
    function swapCHE2JF(uint256 _cheAmount, address _to ) external returns (uint256) {

        address[] memory CHE_USDT_PATH = new address[](2);
        CHE_USDT_PATH[0] = cheToken;
        CHE_USDT_PATH[1] = bridgeToken;

        IERC20(cheToken).safeApprove(address(cheRouter), _cheAmount);
        cheRouter.swapExactTokensForTokens(
                _cheAmount,
                0,
                CHE_USDT_PATH,
                address(this),
                block.timestamp + 100
        );

        address[] memory USDT_JF_PATH = new address[](2);
        USDT_JF_PATH[0] = bridgeToken;
        USDT_JF_PATH[1] = jfToken;

        uint256 bridgeAmount = IERC20(bridgeToken).balanceOf(address(this));
        IERC20(bridgeToken).safeApprove(address(jfRouter), bridgeAmount);
        uint256[] memory amountOut = jfRouter.swapExactTokensForTokens(
                bridgeAmount,
                0,
                USDT_JF_PATH,
                _to,
                block.timestamp + 100
        );

        return amountOut[1];
    }

}