// SPDX-License-Identifier: MIT

pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {Parameterizer} from "./Parameterizer.sol";
import {PLCRVoting} from "./PLCRVoting.sol";

/**
 * @title Registry
 * @author Casper Kjær Rasmussen / @ckryptoon
 * @notice This is the Registry contract you need to build a TCR (Token Curated Registry).
 */
contract Registry {
    //////////////////////////////////////////////////////////////// 
    /// Types                                                    ///
    ////////////////////////////////////////////////////////////////

    struct Listing {
        uint256 applicationExpiry;
        bool whitelisted;
        address owner;
        uint256 unstakedDeposit;
        uint256 challengeId;
	    uint256 exitTime;
        uint256 exitTimeExpiry;
    }

    struct Challenge {
        uint256 rewardPool;
        address challenger;
        bool resolved;
        uint256 stake;
        uint256 totalTokens;
        mapping(address => bool) tokenClaims;
    }

    //////////////////////////////////////////////////////////////// 
    /// State Variables                                          ///
    ////////////////////////////////////////////////////////////////

    mapping(uint256 => Challenge) public challenges;

    mapping(bytes32 => Listing) public listings;

    IERC20 public token;
    PLCRVoting public voting;
    Parameterizer public parameterizer;

    //////////////////////////////////////////////////////////////// 
    /// Events                                                   ///
    ////////////////////////////////////////////////////////////////

    event Application(bytes32 indexed listingHash, uint256 deposit, uint256 appEndDate, string data, address indexed applicant);

    event ChallengeStarted(bytes32 indexed listingHash, uint256 challengeId, string data, uint256 commitEndDate, uint256 revealEndDate, address indexed challenger);

    event Deposited(bytes32 indexed listingHash, uint256 added, uint256 newTotal, address indexed owner);

    event Withdrawn(bytes32 indexed listingHash, uint256 withdrew, uint256 newTotal, address indexed owner);

    event ApplicationWhitelisted(bytes32 indexed listingHash);

    event ApplicationRemoved(bytes32 indexed listingHash);

    event ListingRemoved(bytes32 indexed listingHash);

    event ListingWithdrawn(bytes32 indexed listingHash, address indexed owner);

    event TouchAndRemoved(bytes32 indexed listingHash);

    event ChallengeFailed(bytes32 indexed listingHash, uint256 indexed challengeId, uint256 rewardPool, uint256 totalTokens);

    event ChallengeSucceeded(bytes32 indexed listingHash, uint256 indexed challengeId, uint256 rewardPool, uint256 totalTokens);

    event RewardClaimed(uint256 indexed challengeId, uint256 reward, address indexed voter);

    event ExitInitialized(bytes32 indexed listingHash, uint256 exitTime, uint256 exitDelayEndDate, address indexed owner);

    //////////////////////////////////////////////////////////////// 
    /// Errors                                                   ///
    ////////////////////////////////////////////////////////////////

    error Registry_AddressZeroIsInvalidInput();

    error Registry_ListingIsWhitelisted();

    error Registry_ApplicationAlreadyExists();

    error Registry_AmountIsBelowMinimumDeposit();

    error Registry_TokenTransferFailed();

    error Registry_CallerIsNotListingOwner();

    error Registry_AmountIsHigherThanUnstakedDeposit();

    error Registry_WithdrawalAmountIsTooHigh();

    error Registry_ListingIsNotWhitelisted();

    error Registry_ExitTimerCanNotBeSetDuringChallenge();

    error Registry_ListingExitTimeIsNotZeroAndListingExitTimeHasNotPassed();

    error Registry_ListingExitTimeIsZero();

    error Registry_ExitMustComeAfterExitDelayAndBeforeExitTimeExpires();

    error Registry_ListingIsInApplyStageOrOnWhitelist();

    error Registry_ListingIsChallenged();

    error Registry_ApplicationCanNotBeWhitelistedOrChallengeHasNotBeenResolved();

    error Registry_TokensHasAlreadyBeenClaimed();

    error Registry_ChallengeHasNotBeenResolved();

    error Registry_ChallengeDoesNotExist();

    error Registry_ChallengeHasBeenResolvedButPollHasNotEnded();

    //////////////////////////////////////////////////////////////// 
    /// Constructor                                              ///
    ////////////////////////////////////////////////////////////////

    /**
    @dev Constructor. Can only be called once.
    @param _tokenAddr The address where the ERC20 token contract is deployed.
    @param _votingAddr The address where the PLCRVoting contract is deployed.
    @param _parameterizerAddr The address where the Parameterizer contract is deployed.
    */
    constructor(address _tokenAddr, address _votingAddr, address _parameterizerAddr) {
        if (_tokenAddr == address(0)) revert Registry_AddressZeroIsInvalidInput();
        if (_votingAddr == address(0)) revert Registry_AddressZeroIsInvalidInput();
        if (_parameterizerAddr == address(0)) revert Registry_AddressZeroIsInvalidInput();

        token = IERC20(_tokenAddr);
        voting = PLCRVoting(_votingAddr);
        parameterizer = Parameterizer(_parameterizerAddr);
    }

    //////////////////////////////////////////////////////////////// 
    /// External Functions                                       ///
    ////////////////////////////////////////////////////////////////

    /**
    @dev Allows a user to start an application. Takes tokens from user and sets apply stage end time.
    @param _listingHash The hash of a potential listing a user is applying to add to the registry.
    @param _amount The number of ERC20 tokens a user is willing to potentially stake.
    @param _data Extra data relevant to the application. Think IPFS hashes. ???
    */
    function list(bytes32 _listingHash, uint256 _amount, string calldata _data) external {
        if (isWhitelisted(_listingHash)) revert Registry_ListingIsWhitelisted();
        if (appWasMade(_listingHash)) revert Registry_ApplicationAlreadyExists();
        if (_amount < parameterizer.get("minDeposit")) revert Registry_AmountIsBelowMinimumDeposit();

        Listing storage listing = listings[_listingHash];
        listing.owner = msg.sender;

        listing.applicationExpiry = block.timestamp + parameterizer.get("applyStageLen");
        listing.unstakedDeposit = _amount;
    
        if (!token.transferFrom(listing.owner, address(this), _amount)) revert Registry_TokenTransferFailed();

        emit Application(_listingHash, _amount, listing.applicationExpiry, _data, msg.sender);
    }

    /**
    @dev Allows the owner of a listingHash to increase their unstaked deposit.
    @param _listingHash A listingHash msg.sender is the owner of.
    @param _amount The number of ERC20 tokens to increase a user's unstaked deposit.
    */
    function deposit(bytes32 _listingHash, uint256 _amount) external {
        Listing storage listing = listings[_listingHash];

        if (listing.owner != msg.sender) revert Registry_CallerIsNotListingOwner();

        listing.unstakedDeposit += _amount;

        if (!token.transferFrom(msg.sender, address(this), _amount)) revert Registry_TokenTransferFailed();

        emit Deposited(_listingHash, _amount, listing.unstakedDeposit, msg.sender);
    }

    /**
    @dev Allows the owner of a listingHash to decrease their unstaked deposit.
    @param _listingHash A listingHash msg.sender is the owner of.
    @param _amount The number of ERC20 tokens to withdraw from the unstaked deposit.
    */
    function withdraw(bytes32 _listingHash, uint256 _amount) external {
        Listing storage listing = listings[_listingHash];

        if (listing.owner != msg.sender) revert Registry_CallerIsNotListingOwner();
        if (_amount > listing.unstakedDeposit) revert Registry_AmountIsHigherThanUnstakedDeposit();
        if (listing.unstakedDeposit - _amount > parameterizer.get("minDeposit")) revert Registry_WithdrawalAmountIsTooHigh();

        listing.unstakedDeposit -= _amount;

        if (!token.transfer(msg.sender, _amount)) revert Registry_TokenTransferFailed();

        emit Withdrawn(_listingHash, _amount, listing.unstakedDeposit, msg.sender);
    }

    /**
    @dev Initialize an exit timer for a listing to leave the whitelist.
    @param _listingHash	A listing hash msg.sender is the owner of.
    */
    function initExit(bytes32 _listingHash) external {	
        Listing storage listing = listings[_listingHash];

        if (listing.owner != msg.sender) revert Registry_CallerIsNotListingOwner();
        if (!isWhitelisted(_listingHash)) revert Registry_ListingIsNotWhitelisted();
        if (listing.challengeId != 0 || !challenges[listing.challengeId].resolved) revert Registry_ExitTimerCanNotBeSetDuringChallenge();
        if (listing.exitTime != 0 || block.timestamp < listing.exitTimeExpiry) revert Registry_ListingExitTimeIsNotZeroAndListingExitTimeHasNotPassed();

        listing.exitTime = block.timestamp + parameterizer.get("exitTimeDelay");
	    listing.exitTimeExpiry = listing.exitTime + parameterizer.get("exitPeriodLen");

        emit ExitInitialized(_listingHash, listing.exitTime, listing.exitTimeExpiry, msg.sender);
    }

    /**
    @dev Allow a listing to leave the whitelist.
    @param _listingHash A listing hash msg.sender is the owner of.
    */
    function finalizeExit(bytes32 _listingHash) external {
        Listing storage listing = listings[_listingHash];

        if (listing.owner != msg.sender) revert Registry_CallerIsNotListingOwner();
        if (!isWhitelisted(_listingHash)) revert Registry_ListingIsNotWhitelisted();
        if (listing.challengeId != 0 || !challenges[listing.challengeId].resolved) revert Registry_ExitTimerCanNotBeSetDuringChallenge();
        if (listing.exitTime == 0) revert Registry_ListingExitTimeIsZero();
	    if (listing.exitTime > block.timestamp && block.timestamp > listing.exitTimeExpiry) revert Registry_ExitMustComeAfterExitDelayAndBeforeExitTimeExpires();

        _resetListing(_listingHash);

        emit ListingWithdrawn(_listingHash, msg.sender);
    }

    /**
    @dev Updates an array of listingHashes' status from 'application' to 'listing' or resolve a challenge if one exists.
    @param _listingHashes The listingHashes whose status are being updated.
    */
    function updateStatuses(bytes32[] calldata _listingHashes) external {
        for (uint256 i = 0; i < _listingHashes.length; i++) {
            updateStatus(_listingHashes[i]);
        }
    }

    /**
    @dev Called by a voter to claim their rewards for each completed vote. Someone must call updateStatus() before this can be called.
    @param _challengeIds The PLCR pollIds of the challenges rewards are being claimed for.
    */
    function claimRewards(uint256[] calldata _challengeIds) external {
        // loop through arrays, claiming each individual vote reward
        for (uint256 i = 0; i < _challengeIds.length; i++) {
            claimReward(_challengeIds[i]);
        }
    }

    /**
    @dev Starts a poll for a listingHash which is either in the apply stage or already in the whitelist. Tokens are taken from the challenger and the applicant's deposits are locked.
    @param _listingHash The listingHash being challenged, whether listed or in application
    @param _data Extra data relevant to the challenge. Think IPFS hashes. ???
    */
    function challenge(bytes32 _listingHash, string calldata _data) external returns (uint256 challengeId) {
        Listing storage listing = listings[_listingHash];
        uint256 minDeposit = parameterizer.get("minDeposit");

        if (!appWasMade(_listingHash) || listing.whitelisted) revert Registry_ListingIsInApplyStageOrOnWhitelist();
        if (listing.challengeId != 0 || challenges[listing.challengeId].resolved) revert Registry_ListingIsChallenged();

        if (listing.unstakedDeposit < minDeposit) {
            _resetListing(_listingHash);

            emit TouchAndRemoved(_listingHash);

            return 0;
        }

        uint256 pollId = voting.startPoll(
            parameterizer.get("voteQuorum"),
            parameterizer.get("commitStageLen"),
            parameterizer.get("revealStageLen")
        );

        Challenge storage challengeInstance = challenges[pollId];

        challengeInstance.challenger = msg.sender;
        challengeInstance.rewardPool = (100 - parameterizer.get("dispensationPct")) * minDeposit / 100; // ???
        challengeInstance.stake = minDeposit;
        challengeInstance.resolved = false;
        challengeInstance.totalTokens = 0;

        listing.challengeId = pollId;
        listing.unstakedDeposit -= minDeposit;

        if (!token.transferFrom(msg.sender, address(this), minDeposit)) revert Registry_TokenTransferFailed();

        (uint256 commitEndDate, uint256 revealEndDate,,,) = voting.pollMap(pollId);

        emit ChallengeStarted(_listingHash, pollId, _data, commitEndDate, revealEndDate, msg.sender);

        return pollId;
    }

    //////////////////////////////////////////////////////////////// 
    /// Public Functions                                         ///
    ////////////////////////////////////////////////////////////////

    /**
    @dev Updates a listingHash's status from 'application' to 'listing' or resolve a challenge if one exists.
    @param _listingHash The listingHash whose status is being updated.
    */
    function updateStatus(bytes32 _listingHash) public {
        if (canBeWhitelisted(_listingHash)) {
            _whitelistApplication(_listingHash);
        } else if (challengeCanBeResolved(_listingHash)) {
            _resolveChallenge(_listingHash);
        } else {
            revert Registry_ApplicationCanNotBeWhitelistedOrChallengeHasNotBeenResolved();
        }
    }

    /**
    @dev Called by a voter to claim their reward for each completed vote. Someone must call updateStatus() before this can be called.
    @param _challengeId The PLCR pollId of the challenge a reward is being claimed for.
    */
    function claimReward(uint256 _challengeId) public {
        Challenge storage challengeInstance = challenges[_challengeId];

        if (challengeInstance.tokenClaims[msg.sender]) revert Registry_TokensHasAlreadyBeenClaimed();
        if (!challengeInstance.resolved) revert Registry_ChallengeHasNotBeenResolved();

        uint256 voterTokens = voting.getNumPassingTokens(msg.sender, _challengeId);
        uint256 reward = voterTokens * challengeInstance.rewardPool / challengeInstance.totalTokens;

        challengeInstance.totalTokens -= voterTokens;
        challengeInstance.rewardPool -= reward;
        challengeInstance.tokenClaims[msg.sender] = true;

        if (!token.transfer(msg.sender, reward)) revert Registry_TokenTransferFailed();

        emit RewardClaimed(_challengeId, reward, msg.sender);
    }

    /**
    @dev Calculates the provided voter's token reward for the given poll.
    @param _voter The address of the voter whose reward balance is to be returned.
    @param _challengeId The pollId of the challenge a reward balance is being queried for.
    @return The uint256 indicating the voter's reward.
    */
    function voterReward(address _voter, uint256 _challengeId) public view returns (uint256) {
        uint256 totalTokens = challenges[_challengeId].totalTokens;
        uint256 rewardPool = challenges[_challengeId].rewardPool;
        uint256 voterTokens = voting.getNumPassingTokens(_voter, _challengeId);

        return voterTokens * rewardPool / totalTokens;
    }

    /**
    @dev Determines whether the given listingHash be whitelisted.
    @param _listingHash The listingHash whose status is to be examined.
    */
    function canBeWhitelisted(bytes32 _listingHash) public view returns (bool) {
        uint256 challengeId = listings[_listingHash].challengeId;

        if (appWasMade(_listingHash) && listings[_listingHash].applicationExpiry < block.timestamp && !isWhitelisted(_listingHash) && (challengeId == 0 || challenges[challengeId].resolved)) {
            return true;
        }
            return false;
    }

    /**
    @dev  Returns true if the provided listingHash is whitelisted.
    @param _listingHash The listingHash whose status is to be examined.
    */
    function isWhitelisted(bytes32 _listingHash) public view returns (bool whitelisted) {
        return listings[_listingHash].whitelisted;
    }

    /**
    @dev Returns true if apply was called for this listingHash.
    @param _listingHash The listingHash whose status is to be examined.
    */
    function appWasMade(bytes32 _listingHash) public view returns (bool exists) {
        return listings[_listingHash].applicationExpiry > 0;
    }

    /**
    @dev Returns true if the application/listingHash has an unresolved challenge.
    @param _listingHash The listingHash whose status is to be examined.
    */
    function challengeExists(bytes32 _listingHash) public view returns (bool) {
        uint256 challengeId = listings[_listingHash].challengeId;

        return (listings[_listingHash].challengeId > 0 && !challenges[challengeId].resolved);
    }

    /**
    @dev Determines whether voting has concluded in a challenge for a given listingHash. Throws if no challenge exists.
    @param _listingHash A listingHash with an unresolved challenge.
    */
    function challengeCanBeResolved(bytes32 _listingHash) public view returns (bool) {
        uint256 challengeId = listings[_listingHash].challengeId;

        if (!challengeExists(_listingHash)) revert Registry_ChallengeDoesNotExist();

        return voting.pollEnded(challengeId);
    }

    /**
    @dev Determines the number of tokens awarded to the winning party in a challenge.
    @param _challengeId The challengeId to determine a reward for.
    */
    function determineReward(uint256 _challengeId) public view returns (uint256) {
        if (challenges[_challengeId].resolved && !voting.pollEnded(_challengeId)) revert Registry_ChallengeHasBeenResolvedButPollHasNotEnded();

        // Edge case, nobody voted, give all tokens to the challenger.
        if (voting.getTotalNumberOfTokensForWinningOption(_challengeId) == 0) {
            return 2 * challenges[_challengeId].stake;
        }

        return (2 * challenges[_challengeId].stake) - challenges[_challengeId].rewardPool;
    }

    /**
    @dev Getter for Challenge tokenClaims mappings.
    @param _challengeId The challengeId to query.
    @param _voter The voter whose claim status to query for the provided challengeId.
    */
    function tokenClaims(uint256 _challengeId, address _voter) public view returns (bool) {
        return challenges[_challengeId].tokenClaims[_voter];
    }

    //////////////////////////////////////////////////////////////// 
    /// Private Functions                                        ///
    ////////////////////////////////////////////////////////////////

    /**
    @dev Determines the winner in a challenge. Rewards the winner tokens and either whitelists or de-whitelists the listingHash.
    @param _listingHash A listingHash with a challenge that is to be resolved.
    */
    function _resolveChallenge(bytes32 _listingHash) private {
        uint256 challengeId = listings[_listingHash].challengeId;
        uint256 reward = determineReward(challengeId);

        challenges[challengeId].resolved = true;

        challenges[challengeId].totalTokens = voting.getTotalNumberOfTokensForWinningOption(challengeId);

        if (voting.isPassed(challengeId)) {
            _whitelistApplication(_listingHash);

            listings[_listingHash].unstakedDeposit += reward;

            emit ChallengeFailed(_listingHash, challengeId, challenges[challengeId].rewardPool, challenges[challengeId].totalTokens);
        } else {
            _resetListing(_listingHash);

            if (!token.transfer(challenges[challengeId].challenger, reward)) revert Registry_TokenTransferFailed();

            emit ChallengeSucceeded(_listingHash, challengeId, challenges[challengeId].rewardPool, challenges[challengeId].totalTokens);
        }
    }

    /**
    @dev Called by updateStatus() if the applicationExpiry date passed without a challenge being made. Called by resolveChallenge() if an application/listing beat a challenge.
    @param _listingHash The listingHash of an application/listingHash to be whitelisted.
    */
    function _whitelistApplication(bytes32 _listingHash) private {
        if (!listings[_listingHash].whitelisted) {
            emit ApplicationWhitelisted(_listingHash);
        }
        listings[_listingHash].whitelisted = true;
    }

    /**
    @dev Deletes a listingHash from the whitelist and transfers tokens back to owner.
    @param _listingHash The listing hash to delete.
    */
    function _resetListing(bytes32 _listingHash) private {
        Listing storage listing = listings[_listingHash];

        if (listing.whitelisted) {
            emit ListingRemoved(_listingHash);
        } else {
            emit ApplicationRemoved(_listingHash);
        }

        address owner = listing.owner;
        uint256 unstakedDeposit = listing.unstakedDeposit;

        delete listings[_listingHash];

        if (unstakedDeposit > 0){
            if (!token.transfer(owner, unstakedDeposit)) revert Registry_TokenTransferFailed();
        }
    }
}
