// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC20Metadata} from "@openzeppelin-4/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {SafeERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IStrategyConcLiq} from "../interfaces/beefy/IStrategyConcLiq.sol";

/**
 * @dev Implementation of a vault to deposit funds for yield optimizing.
 * This is the contract that receives funds and that users interface with.
 * The yield optimizing strategy itself is implemented in a separate 'Strategy.sol' contract.
 */
contract BeefyVaultConcLiq is ERC20PermitUpgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    
    /// @notice The strategy currently in use by the vault.
    IStrategyConcLiq public strategy;
   
    /// @notice The initial shares that are burned as part of the first vault deposit. 
    uint256 private constant MINIMUM_SHARES = 10**3;

    /// @notice The precision used to calculate the shares.
    uint256 private constant PRECISION = 1e36;

    /// @notice The address we are sending the burned shares to.
    address private constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    // Errors
    error NoShares();
    error TooMuchSlippage();
    error NotEnoughTokens();

    // Events 
    event Deposit(address indexed user, uint256 shares, uint256 amount0, uint256 amount1, uint256 fee0, uint256 fee1);
    event Withdraw(address indexed user, uint256 shares, uint256 amount0, uint256 amount1);

    /**
     * @notice Initializes the vault, sets the strategy name and creates a new token.
     * @param _strategy the address of the strategy.
     * @param _name the name of the vault token.
     * @param _symbol the symbol of the vault token.
     */
     function initialize(
        address _strategy,
        string calldata _name,
        string calldata _symbol
    ) external initializer {
        __ERC20_init(_name, _symbol);
        __ERC20Permit_init(_name);
        __Ownable_init();
        __ReentrancyGuard_init();
        strategy = IStrategyConcLiq(_strategy);
    }

    /** 
     * @notice returns whether the pool is calm for deposits
     * @return boolean true if the pool is calm 
    */
    function isCalm() external view returns (bool) {
        return strategy.isCalm();
    }

    /** 
     * @notice The fee for swaps in the underlying pool in 18 decimals
     * @return uint256 swap fee for the underlying pool
    */
    function swapFee() public view returns (uint256) {
        return strategy.swapFee();
    }

    /** 
     * @notice returns the concentrated liquidity pool address
     * @return _want the address of the concentrated liquidity pool
    */
    function want() external view returns (address _want) {
        return strategy.pool();
    }

    /** @notice returns the tokens that the strategy wants
     * @return token0 the address of the first token
     * @return token1 the address of the second token
    */
    function wants() public view returns (address token0, address token1) {
        token0 = strategy.lpToken0();
        token1 = strategy.lpToken1();
    }

    /**
     * @notice It calculates the total underlying value of {tokens} held by the system.
     * It takes into account the vault contract balance, the strategy contract balance
     *  and the balance deployed in other contracts as part of the strategy.
     * @return amount0 the amount of token0
     * @return amount1 the amount of token1
     */
    function balances() public view returns (uint amount0, uint amount1) {
        (amount0, amount1) = IStrategyConcLiq(strategy).balances();
    }

    /**
     * @notice Returns the amount of token0 and token1 that a number of shares represents.
     * @param _shares the number of shares to convert to tokens.
     * @return amount0 the amount of token0 a user will recieve for the shares.
     * @return amount1 the amount of token1 a user will recieve for the shares.
     */
    function previewWithdraw(uint256 _shares) external view returns (uint256 amount0, uint256 amount1) {
        (uint bal0, uint bal1) = balances();

        uint256 _totalSupply = totalSupply();
        amount0 = (bal0 * _shares) / _totalSupply;
        amount1 = (bal1 * _shares) / _totalSupply;
    }

      /**
     * @notice Get a expected shares amount for token deposits. 
     * @param _amount0 the amount of token0 to deposit.
     * @param _amount1 the amount of token1 to deposit.
     * @return shares amount of shares that the deposit will represent.
     */
    function previewDeposit(uint256 _amount0, uint256 _amount1) external view returns (uint256 shares, uint256 amount0, uint256 amount1, uint256 fee0, uint256 fee1) {
        uint256 price = strategy.price();

        (uint bal0, uint bal1) = balances();

        (amount0, amount1, fee0, fee1) = _getTokensRequired(price, _amount0, _amount1, bal0, bal1, swapFee());

        uint256 _totalSupply = totalSupply();

        if (_totalSupply == 0) {
            bal0 = _amount0;
            bal1 = _amount1;
        }

        shares = (amount1 - fee1) + ((amount0 - fee0) * price / PRECISION); 

        if (_totalSupply > 0) {
            // How much of wants() do we have in token 1 equivalents;
            uint256 token1EquivalentBalance = ((((bal0 + fee0) * price) + PRECISION - 1) / PRECISION) + (bal1 + fee1);
            shares = shares * _totalSupply / token1EquivalentBalance;
        } else {
            // First user donates MINIMUM_SHARES for security of the vault. 
            shares =  shares - MINIMUM_SHARES;
        }
    }

    /// @notice Get the amount of tokens required to deposit to reach the desired balance of the strategy.
    function _getTokensRequired(uint256 _price, uint256 _amount0, uint256 _amount1, uint256 _bal0, uint256 _bal1, uint256 _swapFee) private pure returns (uint256 depositAmount0, uint256 depositAmount1, uint256 feeAmount0, uint256 feeAmount1) {
        // get the amount of bal0 that is equivalent to bal1
        if (_bal0 == 0 && _bal1 == 0) return (_amount0, _amount1, 0, 0);

        uint256 bal0InBal1 = (_bal0 * _price) / PRECISION;

        // check which side is lower and supply as much as possible
        if (_bal1 < bal0InBal1) {
            uint256 owedAmount0 = _bal1 + _amount1 > bal0InBal1
                ? (_bal1 + _amount1 - bal0InBal1) * PRECISION / _price 
                : 0;

            if (owedAmount0 > _amount0) {
                depositAmount0 = _amount0;
                depositAmount1 = _amount1 - ( (owedAmount0 - _amount0) * _price / PRECISION );
            } else {
                depositAmount0 = owedAmount0;
                depositAmount1 = _amount1;
            }

            uint256 fill = _amount1 < (bal0InBal1 - _bal1) ? _amount1 : (bal0InBal1 - _bal1);
            uint256 slidingFee = 
                (bal0InBal1 * PRECISION + (owedAmount0 * _price)) 
                / (bal0InBal1 + _bal1 + fill + (2 * owedAmount0 * _price / PRECISION));

            feeAmount1 = fill * (_swapFee * slidingFee / PRECISION) / 1e18;
        } else {
            uint256 owedAmount1 = bal0InBal1 + ( _amount0 * _price / PRECISION ) > _bal1
                ? bal0InBal1 + ( _amount0 * _price / PRECISION ) - _bal1
                : 0;
               
            if (owedAmount1 > _amount1) {
                depositAmount0 = _amount0 - ( (owedAmount1 - _amount1) * PRECISION / _price);
                depositAmount1 = _amount1;
            } else {
                depositAmount0 = _amount0;
                depositAmount1 = owedAmount1;
            }

            uint256 fill = _amount0 < (_bal1 - bal0InBal1) * PRECISION / _price
                ? _amount0 
                : (_bal1 - bal0InBal1) * PRECISION / _price;
            uint256 slidingFee =
                (_bal1 + owedAmount1) * PRECISION
                / (bal0InBal1 + _bal1 + (fill * _price / PRECISION) + (2 * owedAmount1));

            feeAmount0 = fill * (_swapFee * slidingFee / PRECISION) / 1e18;
        }
    }

    /**
     * @notice The entrypoint of funds into the system. People deposit with this function
     * into the vault. The vault is then in charge of sending funds into the strategy.
     * @dev Use previewDeposit to find the proper ratio to deposit into the vault. 
     * @param _amount0 the amount of token0 to deposit.
     * @param _amount1 the amount of token1 to deposit.
     * @param _minShares the minimum amount of shares that the user wants to recieve with slippage.
     */
    function deposit(uint256 _amount0, uint256 _amount1, uint256 _minShares) public nonReentrant {
        (address token0, address token1) = wants();
        
        // Have the strategy remove all liquidity from the pool.
        strategy.beforeAction();

        /// @dev Do not allow deposits of inflationary tokens.
        // Transfer funds from user and send to strategy.
        (uint256 _bal0, uint256 _bal1) = balances();
        uint256 price = strategy.price();
        (uint256 amount0, uint256 amount1, uint256 fee0, uint256 fee1) = 
            _getTokensRequired(price, _amount0, _amount1, _bal0, _bal1, swapFee());
        if (amount0 > _amount0 || amount1 > _amount1) revert NotEnoughTokens();
        
        if (amount0 > 0) IERC20Upgradeable(token0).safeTransferFrom(msg.sender, address(strategy), amount0);
        if (amount1 > 0) IERC20Upgradeable(token1).safeTransferFrom(msg.sender, address(strategy), amount1);

        { // scope to avoid stack too deep errors
            (uint256 _after0, uint256 _after1) = balances();
            amount0 = _after0 - _bal0;
            amount1 = _after1 - _bal1;
        }

        strategy.deposit();
        uint256 shares = (amount1 - fee1) + ((amount0 - fee0) * price / PRECISION);

        uint256 _totalSupply = totalSupply();
        if (_totalSupply > 0) {
            // How much of wants() do we have in token 1 equivalents;
            shares = shares * _totalSupply / (((((_bal0 + fee0) * price) + PRECISION - 1) / PRECISION) + (_bal1 + fee1));
        } else {
            // First user donates MINIMUM_SHARES for security of the vault. 
            shares =  shares - MINIMUM_SHARES;
            _mint(BURN_ADDRESS, MINIMUM_SHARES); // permanently lock the first MINIMUM_SHARES
        }

        if (shares < _minShares) revert TooMuchSlippage();
        if (shares == 0) revert NoShares();

        _mint(msg.sender, shares);
        emit Deposit(msg.sender, shares, amount0, amount1, fee0, fee1);
    }

    /**
     * @dev A helper function to call withdraw() with all the sender's funds.
     * @param _minAmount0 the minimum amount of token0 that the user wants to recieve with slippage.
     * @param _minAmount1 the minimum amount of token1 that the user wants to recieve with slippage.
     */
    function withdrawAll(uint256 _minAmount0, uint256 _minAmount1) external {
        withdraw(balanceOf(msg.sender), _minAmount0, _minAmount1);
    }

    /**
     * @notice Function to exit the system. The vault will withdraw the required tokens
     * from the strategy and pay up the token holder. A proportional number of IOU
     * tokens are burned in the process.
     * @param _shares the number of shares to withdraw.
     * @param _minAmount0 the minimum amount of token0 that the user wants to recieve with slippage.
     * @param _minAmount1 the minimum amount of token1 that the user wants to recieve with slippage.
     */
    function withdraw(uint256 _shares, uint256 _minAmount0, uint256 _minAmount1) public {
        if (_shares == 0) revert NoShares();
        
        // Withdraw All Liquidity to Strat for Accounting.
        strategy.beforeAction();

        uint256 _totalSupply = totalSupply();
        _burn(msg.sender, _shares);

        (uint256 _bal0, uint256 _bal1) = balances();

        uint256 _amount0 = (_bal0 * _shares) / _totalSupply;
        uint256 _amount1 = (_bal1 * _shares) / _totalSupply;

        strategy.withdraw(_amount0, _amount1);

        if (
            _amount0 < _minAmount0 || 
            _amount1 < _minAmount1 ||
            (_amount0 == 0 && _amount1 == 0)
        ) revert TooMuchSlippage();

        (address token0, address token1) = wants();
        IERC20Upgradeable(token0).safeTransfer(msg.sender, _amount0);
        IERC20Upgradeable(token1).safeTransfer(msg.sender, _amount1);

        emit Withdraw(msg.sender, _shares, _amount0, _amount1);
    }

    /**
     * @dev Rescues random funds stuck that the strat can't handle.
     * @param _token address of the token to rescue.
     */
    function inCaseTokensGetStuck(address _token) external onlyOwner {
        uint256 amount = IERC20Upgradeable(_token).balanceOf(address(this));
        IERC20Upgradeable(_token).safeTransfer(msg.sender, amount);
    }
}