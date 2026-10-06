// SPDX-License-Identifier: MIT

// This is considered an Exogenous, Decentralized, Anchored (pegged), Crypto Collateralized low volitility coin

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity ^0.8.20;

import {DecentralizedStableCoin} from "./Stablecoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title DSCEngine
 * @author Prince Maurya
 *
 * Stablecoin is designed to be pegged to 1$. It is similar to Dai but with no governance and no fees.
 * It is backed by WETH and WBTC.
 * Exogenous collateral.
 * Dollar Pegged.
 * Algorithmically Stable.
 * Stablecoin should always be overcollaterised.
 *
 * @notice This is the core contract for stablecoin.sol
 * *
 */
contract DSCEngine is ReentrancyGuard {
    //Errors
    error DSCEngine__NeedsCollateralAmountMoreThanZero();
    error DSCEngine__TokenAddressAndPriceFeedAddressMustBeSameLength();
    error DSCEngine__Not_Allowed_Token();
    error DSCEngine__TransferFailed();
    error DSCEngine__HealthFactorISBroken(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorISFine();
    error DSCEngine__HealthFactorNotImproved();
    error DSCEngine_HealthFactorImproved();

    //State Variables
    mapping(address token => address pricefeed) private s_priceFeed; //token to its pricefeed address
    mapping(address user => mapping(address token => uint256 amount))
        private s_collateralDeposited; //mapping of mapping for a user to his collateral token and its amount
    mapping(address user => uint256 amountMSDT) private s_MSDTMinted; //mapping of user to the amount of msdt minted by him
    address[] private s_collateralTokens; //array of collateral tokens

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100; // together there represent
    uint256 private constant LIQUIDATION_BONUS = 10;

    DecentralizedStableCoin private immutable i_msdt;

    //Events
    event CollateralDeposited(
        address indexed user,
        address indexed collateralTokenAddress,
        uint256 indexed amountDeposited
    );

    event CollateralRedeemed(
        address indexed redeemedFrom,
        address indexed redeemedTo,
        address indexed token,
        uint256 amount
    );

    //Modifiers
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsCollateralAmountMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeed[token] == address(0)) {
            revert DSCEngine__Not_Allowed_Token();
        }
        _;
    }

    //Functions
    /**
     * @notice Constructor for the DSCEngine Contract
     * @param tokenAddresses Array of Tokens Allowed as Collateral
     * @param priceFeedAddresses Array of PriceFeed Addresses corresponding to the tokens
     * @param msdtAddress Address of the Stablecoin Contract
     */
    constructor(
        address[] memory tokenAddresses,
        address[] memory priceFeedAddresses,
        address msdtAddress
    ) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressAndPriceFeedAddressMustBeSameLength();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeed[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_msdt = DecentralizedStableCoin(msdtAddress);
    }

    //External Functions

    /**
     * @param tokenCollateralAddress The address of token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     * @param amountMsdtToMint  The amount of Stablecoin to Mint
     * @notice this function will deposit your collateral and mint MSDT in one transaction
     */
    function depositColleteralAndMintMSDT(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountMsdtToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintMSDT(amountMsdtToMint);
    }

    /**
     * @notice follows CEI: Check, Effect, Interaction
     * @param tokenCollateralAddress The address of token to be deposit as Colleteral
     * @param amountCollateral The amount of Collateral to deposit
     */
    function depositCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    )
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][
            tokenCollateralAddress
        ] += amountCollateral;
        emit CollateralDeposited(
            msg.sender,
            tokenCollateralAddress,
            amountCollateral
        );
        bool success = IERC20(tokenCollateralAddress).transferFrom(
            msg.sender,
            address(this),
            amountCollateral
        ); //msg.sender is the user who is depositing the collateral, while address(this) is address of this contract
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function redeemColleteralForMSDT(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountMsdtToBurn
    ) external {
        burnMSDT(amountMsdtToBurn);
        redeemColleteral(tokenCollateralAddress, amountCollateral);
    }

    //health factor should be over 1 after collateral is pulled
    //must follow check efferct interact

    function redeemColleteral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    ) public moreThanZero(amountCollateral) nonReentrant {
        _redeemCollateral(
            msg.sender,
            msg.sender,
            tokenCollateralAddress,
            amountCollateral
        );
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice follows CEI: Check, Effect, Interaction
     * @param amountMSDTToMint The amount of MSDT to mint
     */
    function mintMSDT(
        uint256 amountMSDTToMint
    ) public moreThanZero(amountMSDTToMint) nonReentrant {
        //moreThankZero: Check
        s_MSDTMinted[msg.sender] += amountMSDTToMint; //Effect
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_msdt.mint(msg.sender, amountMSDTToMint); //Interaction
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnMSDT(uint256 amount) public moreThanZero(amount) {
        _burnMsdt(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function liquidate(
        address collateral,
        address user,
        uint256 debtToCover
    ) external moreThanZero(debtToCover) nonReentrant {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorISFine();
        }

        //burn msdt debt
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(
            collateral,
            debtToCover
        );
        //10% bonus for liquidetor
        uint256 bonusCollateral = (tokenAmountFromDebtCovered *
            LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;

        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered +
            bonusCollateral;
        _redeemCollateral(
            user,
            msg.sender,
            collateral,
            totalCollateralToRedeem
        );
        _burnMsdt(debtToCover, user, msg.sender);
        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        revert DSCEngine_HealthFactorImproved();
    }

    function getHealthFunction() external view {}

    // Private and Internal View+++++++++++ Functions

    function _getAccountInfo(
        address user
    )
        private
        view
        returns (uint256 totalMSDTMinted, uint256 collateralValueInUsd)
    {
        totalMSDTMinted = s_MSDTMinted[user];
        collateralValueInUsd = _getAccountCollateralValue(user);
    }

    function _burnMsdt(
        uint256 amountMsdtToBurn,
        address onBehalfOf,
        address dscFrom
    ) public {
        s_MSDTMinted[onBehalfOf] -= amountMsdtToBurn;
        bool success = i_msdt.transferFrom(
            dscFrom,
            address(this),
            amountMsdtToBurn
        );
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_msdt.burn(amountMsdtToBurn);
    }

    function _redeemCollateral(
        address from,
        address to,
        address tokenCollateralAddress,
        uint256 amountCollateral
    ) public moreThanZero(amountCollateral) {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(
            from,
            to,
            tokenCollateralAddress,
            amountCollateral
        );
        bool success = IERC20(tokenCollateralAddress).transfer(
            to,
            amountCollateral
        );
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        //1) Check health factor, it tells if someone has enough collateral to back the msdt they have minted
        //2) Revert if health factor is low
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorISBroken(userHealthFactor);
        }
    }

    /**
     * _healthfactor function
     * Tells us how close a user is to liquidation
     * If hf goes below 1 then user may ger liquidated.
     * _ before functionname tells us this is internal function
     * view tells us this function is not changing the state of the contract
     * LIQUIDATION_THRESHOLD being 50% means, if your collateral Value is 100, then you can mint atmost 50 MSDT
     * LIQUIDATION_PECISION is 100 so that we can get 50% of original collateral by calculating as we dont have decimal
     */

    function _healthFactor(address user) private view returns (uint256) {
        (
            uint256 totalMSDTMinted,
            uint256 collateralValueInUsd
        ) = _getAccountInfo(user);
        uint256 collateralAdjustedForThershold = (collateralValueInUsd *
            LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        //Why multiply by PRECISION (1e18)?
        //Solidity has no decimals. Without it:
        //Without PRECISION: 750e18 / 600e18 = 1   Truncated! Loses the .25

        // eg 150$ ETH, MSDT minted: 100$ => we should liquidate
        //150e18*50/100=75e18
        //75e18*1e18/100e18,  75e18/100e18 <1
        // eg2 1000$ eth, msdt minted 100$
        //h
        return (collateralAdjustedForThershold * PRECISION) / totalMSDTMinted;
    }

    //Public And External Functions

    function getTokenAmountFromUsd(
        address token,
        uint256 usdAmountInWei
    ) public view returns (uint256) {
        AggregatorV3Interface pricefeed = AggregatorV3Interface(
            s_priceFeed[token]
        );
        (, int256 price, , , ) = pricefeed.latestRoundData();
        return
            (usdAmountInWei * PRECISION) /
            (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function _getAccountCollateralValue(
        address user
    ) public view returns (uint256) {
        uint256 totalCollaterlValueInUsd;
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollaterlValueInUsd += getUsdValue(token, amount);
        }
        return totalCollaterlValueInUsd;
    }

    function getUsdValue(
        address token,
        uint256 amount
    ) public view returns (uint256) {
        AggregatorV3Interface pricefeed = AggregatorV3Interface(
            s_priceFeed[token]
        );
        (, int256 price, , , ) = pricefeed.latestRoundData();

        return
            ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }
}
