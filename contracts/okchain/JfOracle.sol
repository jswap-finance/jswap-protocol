pragma solidity =0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/EnumerableSet.sol";
import "../interface/IJfOracle.sol";
import "../interface/IJswapFactory.sol";
import "../libraries/JswapLibrary.sol";
import "./PriceOracle.sol";

contract JfOracle is IJfOracle, PriceOracle, Ownable {
    using FixedPoint for *;
    using SafeMathJswap for uint;
    using EnumerableSet for EnumerableSet.AddressSet;

    // USDT was chosen
    address public valuatToken;
    address public jfToken;
    // USDK, BTCK 1:1 USDT
    mapping(address => bool) public stableToken;
    // The most common paired Token, ETH,ORT etc.
    EnumerableSet.AddressSet private _routerlist;

    event ConvertJfUnexpected(address indexed txOrigin, address tokenIn, uint256 amountIn);

    constructor(address _factory, address _jfToken, address _valuatToken ) PriceOracle(_factory) public {
        jfToken = _jfToken;
        valuatToken = _valuatToken;
    }
 
    function setStableToken(address _token, bool _stable) public onlyOwner {
        stableToken[_token] = _stable;
    }

    function convert2JF(address _token, uint256 _amount) external override returns (uint256 _jfAmount) {
        if(_token == jfToken) {
            _jfAmount = _amount;
        }else {
            // token 2 USDT
            uint256 _stableAmount = convert2ValuatToken(_token, _amount, valuatToken);
            // uint256 _jfPrice = jfPrice.averagePrice();
            if(_stableAmount > 0) {
                _jfAmount =  _consult(valuatToken, _stableAmount, jfToken);
            }else {
                _jfAmount = convert2ValuatToken(_token, _amount, jfToken);
            }
        }
    }

    function convert2ValuatToken( address _tokenIn, uint256 _amountIn, address _dstOut ) private returns (uint256) {
        if(stableToken[_tokenIn]) {
            return _amountIn;
        }else if(JswapLibrary.pairFor(factory, _tokenIn, _dstOut) != address(0))  {
            return _consult( _tokenIn, _amountIn, _dstOut);
        }else{
            uint256 length = getRouterlength();
            for (uint256 index = 0; index < length; index++) {
                address intermediate = getRouter(index);
                if (
                    _tokenIn != intermediate && 
                    intermediate != _dstOut && 
                    JswapLibrary.pairFor(factory, _tokenIn, intermediate) != address(0) 
                    && JswapLibrary.pairFor(factory, intermediate, _dstOut) != address(0)
                ) {
                    uint256 interQuantity = _consult(_tokenIn, _amountIn, intermediate );
                    return _consult(intermediate, interQuantity, _dstOut);
                }
            }
        }
    }

    function _consult(address tokenIn, uint amountIn, address tokenOut) public returns (uint amountOut) {
        amountOut = consult(tokenIn, amountIn, tokenOut);
        //mint JF
        if( tokenOut == jfToken ) {
            //min Pirce = 0.1 USDT
            if(!stableToken[tokenIn]) {   
                 amountOut = 0;
                 emit ConvertJfUnexpected(tx.origin, tokenIn, amountIn );
            } else if(amountOut > amountIn.mul(10)) {
                    amountOut = amountIn.mul(10);
            }
        }
    }

    // Price Router
    function addRouter(address _addToken) public onlyOwner returns (bool) {
        require(_addToken != address(0), "Router token is the zero address");
        return _routerlist.add( _addToken);
    }

    function delRouter(address _delToken) public onlyOwner returns (bool) {
        require(_delToken != address(0), "Router token is the zero address");
        return _routerlist.remove( _delToken);
    }

    function getRouter(uint256 _index) public view returns (address){
        require(_index <= getRouterlength(), "Router index out of bounds");
        return _routerlist.at( _index);
    }

    function getRouterlength() public view returns (uint256) {
        return _routerlist.length();
    }
}
