pragma solidity ^0.5.1;
import "abdk-libraries-solidity/ABDKMath64x64.sol";
import { IERC20 } from "openzeppelin-solidity/contracts/token/ERC20/IERC20.sol";
import { ERC1155 } from "./ERC1155/ERC1155.sol";
import { CTHelpers } from "./CTHelpers.sol";

/// We have three kinds of ERC-1155 token ID
/// - a combination of market ID, collateral address, and customer address (conditional tokens);
/// - a collateral address (donated collateral tokens)
/// - a combination of TOKEN_STAKED and collateral address (staked collateral tokens)
contract ConditionalTokensMany is ERC1155 {
    // TODO: ERC-1155 collateral.
    // TODO: Getters.
    // TODO: Oracle based (with quadratic upgradeable voting) recovery of lost accounts.

    using ABDKMath64x64 for int128;

    enum CollateralKind { TOKEN_STAKED }

    uint constant INITIAL_CUSTOMER_BALANCE = 1000 * 10**18; // an arbitrarily choosen value

    event MarketCreated(address oracle, uint64 marketId);

    event CustomerRegistered(
        address customer,
        uint64 market,
        bytes data
    );

    event DonateERC20Collateral(
        IERC20 indexed collateralToken,
        address sender,
        uint256 amount,
        bytes data
    );

    event StakeERC20Collateral(
        IERC20 indexed collateralToken,
        address sender,
        uint256 amount,
        bytes data
    );

    event TakeBackERC20Collateral(
        IERC20 indexed collateralToken,
        address sender,
        uint256 amount,
        bytes data
    );

    event ReportedDenominator(
        uint64 indexed market,
        address indexed oracle,
        uint256 denominator
    );

    event ReportedNumerator(
        uint64 indexed market,
        address indexed oracle,
        address customer,
        uint256 numerator
    );

    event ReportedNumeratorsBatch(
        uint64 indexed market,
        address indexed oracle,
        address[] addresses,
        uint256[] numerators
    );

    event OracleFinished(address indexed oracle);

    event PayoutRedemption(
        address redeemer,
        IERC20 indexed collateralToken,
        uint64 indexed market,
        address customer,
        uint payout
    );

    uint64 private maxMarket; // FIXME: will 64 bit be enough after 100 years?!

    // TODO: Count numbers of customers per market and/or total balances.
    /// Mapping from market to oracle.
    mapping(uint64 => address) public oracles;
    /// Whether an oracle finished its work.
    mapping(uint64 => bool) public marketFinished;
    /// Mapping (market => (customer => numerator)) for payout numerators.
    mapping(uint64 => mapping(address => uint256)) public payoutNumerators; // TODO: hash instead?
    /// Mapping (market => denominator) for payout denominators.
    mapping(uint64 => uint) public payoutDenominator;
    /// All conditonal tokens,
    mapping(uint256 => bool) public conditionalTokens;
    /// Total collaterals per market.
    mapping(address => mapping(uint64 => uint256)) collateralTotals; // TODO: hash instead?
    /// Total conditional market balances
    mapping(uint64 => uint256) marketTotalBalances; // TODO: hash instead?

    /// Register ourselves as an oracle for a new market.
    function createMarket() external {
        uint64 marketId = maxMarket++;
        oracles[marketId] = msg.sender;
        emit MarketCreated(msg.sender, marketId);
    }

    /// Donate funds in a ERC20 token.
    /// First need to approve the contract to spend the token.
    /// Not recommended to donate after any oracle has finished, because funds may be (partially) lost.
    function donate(IERC20 collateralToken, uint64 market, uint256 amount, bytes calldata data) external {
        _collateralIn(collateralToken, market, amount);
        _mint(msg.sender, _collateralDonatedTokenId(collateralToken, market), amount, data);
        emit DonateERC20Collateral(collateralToken, msg.sender, amount, data);
    }

    /// Donate funds in a ERC20 token.
    /// First need to approve the contract to spend the token.
    /// The stake is lost if either: the prediction period ends or the staker loses his private key (e.g. dies)
    /// Not recommended to stake after any oracle has finished, because funds may be (partially) lost (and you could not unstake).
    function stakeCollateral(IERC20 collateralToken, uint64 market, uint256 amount, bytes calldata data) external {
        _collateralIn(collateralToken, market, amount);
        _mint(msg.sender, _collateralStakedTokenId(collateralToken, market), amount, data);
        emit StakeERC20Collateral(collateralToken, msg.sender, amount, data);
    }

    function takeStakeBack(IERC20 collateralToken, uint64 market, uint256 amount, bytes calldata data) external {
        require(marketFinished[market], "too late");
        uint tokenId = _collateralStakedTokenId(collateralToken, market);
        collateralTotals[address(collateralToken)][market] = collateralTotals[address(collateralToken)][market].sub(amount);
        require(collateralToken.transfer(msg.sender, amount), "cannot transfer");
        _burn(msg.sender, tokenId, amount);
        emit TakeBackERC20Collateral(collateralToken, msg.sender, amount, data);
    }

    // TODO: Ability to register somebody other as a customer. Useful for oracles.
    // FIXME: Need to register for each weighted sub-market. That's bad. (Need to abolish registration and?) instead have 1000 tokens by default?
    function registerCustomer(uint64 market, bytes calldata data) external {
        uint256 conditionalTokenId = _conditionalTokenId(market, msg.sender);
        require(!conditionalTokens[conditionalTokenId], "customer already registered");
        conditionalTokens[conditionalTokenId] = true;
        _mint(msg.sender, conditionalTokenId, INITIAL_CUSTOMER_BALANCE, data);
        marketTotalBalances[market] += INITIAL_CUSTOMER_BALANCE; // No chance of overflow.
        emit CustomerRegistered(msg.sender, market, data);
    }

    /// @dev Called by the oracle for reporting results of conditions. Will set the payout vector for the condition with the ID ``keccak256(abi.encodePacked(oracle, questionId, outcomeSlotCount))``, where oracle is the message sender, questionId is one of the parameters of this function, and outcomeSlotCount is the length of the payouts parameter, which contains the payoutNumerators for each outcome slot of the condition.
    // TODO: Make it a nontransferrable ERC-1155 token?
    // FIXME: If the customer is not registered?
    // FIXME: What if called second time for the same customer?
    function reportNumerator(uint64 market, address customer, uint256 numerator) external
        _isOracle(market)
    {
        payoutNumerators[market][customer] = numerator;
        payoutDenominator[market] += numerator;
        emit ReportedNumerator(market, msg.sender, customer, numerator);
    }

    /// @dev Called by the oracle for reporting results of conditions. Will set the payout vector for the condition with the ID ``keccak256(abi.encodePacked(oracle, questionId, outcomeSlotCount))``, where oracle is the message sender, questionId is one of the parameters of this function, and outcomeSlotCount is the length of the payouts parameter, which contains the payoutNumerators for each outcome slot of the condition.
    function reportNumeratorsBatch(uint64 market, address[] calldata addresses, uint256[] calldata numerators) external
        _isOracle(market)
    {
        require(addresses.length == numerators.length, "length mismatch");
        for (uint i = 0; i < addresses.length; ++i) {
            address customer = addresses[i];
            uint256 numerator = numerators[i];
            payoutNumerators[market][customer] = numerator;
            payoutDenominator[market] += numerator;
        }
        emit ReportedNumeratorsBatch(market, msg.sender, addresses, numerators);
    }

    function finishMarket(uint64 market) external
        _isOracle(market)
    {
        marketFinished[market] = true;
        emit OracleFinished(msg.sender);
    }

    function redeemPosition(IERC20 collateralToken, uint64 market, address customer) external {
        require(marketFinished[market], "too early"); // to prevent the denominator or the numerators change meantime
        uint256 amount = _collateralBalanceOf(collateralToken, market, customer);
        payoutNumerators[market][customer] = 0;
        emit PayoutRedemption(msg.sender, collateralToken, market, customer, amount);
        collateralToken.transfer(customer, amount); // last to prevent reentrancy attack
    }

    // TODO: Make it a ERC-1155 token balance?
    function collateralBalanceOf(IERC20 collateralToken, uint64 market, address customer) external view returns (uint256) {
        return _collateralBalanceOf(collateralToken, market, customer);
    }

    function _collateralTokenId(IERC20 collateralToken, uint64 market) private pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(market, collateralToken)));
    }

    function _conditionalTokenId(uint64 market, address customer) private pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(market, customer)));
    }

    // TODO: Slow to recalculate.
    function _collateralBalanceOf(IERC20 collateralToken, uint64 market, address customer) internal view returns (uint256) {
        uint256 numerator = uint256(payoutNumerators[market][customer]);
        uint256 denominator = payoutDenominator[market];
        uint256 customerBalance = balanceOf(customer, _conditionalTokenId(market, customer));
        uint256 collateralBalance = collateralTotals[address(collateralToken)][market];
        // Rounded to below for no out-of-funds:
        int128 marketShare = ABDKMath64x64.divu(customerBalance, marketTotalBalances[market]);
        int128 userShare = ABDKMath64x64.divu(numerator, denominator);
        return marketShare.mul(userShare).mulu(collateralBalance);
    }

    function _collateralStakedTokenId(IERC20 collateralToken, uint64 market) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(collateralToken, market)));
    }

    function _collateralDonatedTokenId(IERC20 collateralToken, uint64 market) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(uint8(CollateralKind.TOKEN_STAKED), collateralToken, market)));
    }

    function _collateralIn(IERC20 collateralToken, uint64 market, uint256 amount) private {
        require(collateralToken.transferFrom(msg.sender, address(this), amount), "cannot transfer");
        collateralTotals[address(collateralToken)][market] += amount; // FIXME: Overflow possible?
    }

    modifier _isOracle(uint64 market) {
        require(oracles[market] == msg.sender, "not the oracle");
        _;
    }
}
