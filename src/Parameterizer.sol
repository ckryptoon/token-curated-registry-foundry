// SPDX-License-Identifier: MIT

pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {PLCRVoting} from "./PLCRVoting.sol";

/**
 * @title Paramterizer
 * @author Casper Kjær Rasmussen / @ckryptoon
 * @notice This is the Parameterizer contract you need to build a TCR (Token Curated Registry).
 */
contract Parameterizer {
    //////////////////////////////////////////////////////////////// 
    /// Types                                                    ///
    ////////////////////////////////////////////////////////////////

    struct ParamProposal {
        uint256 appExpiry;
        uint256 challengeID;
        uint256 deposit;
        string name;
        address owner;
        uint256 processBy;
        uint256 value;
    }

    struct Challenge {
        uint256 rewardPool;
        address challenger;
        bool resolved;
        uint256 stake;
        uint256 winningTokens;
        mapping(address => bool) tokenClaims;
    }

    //////////////////////////////////////////////////////////////// 
    /// State Variables                                          ///
    ////////////////////////////////////////////////////////////////

    mapping(bytes32 => uint256) public params;

    mapping(uint256 => Challenge) public challenges;

    mapping(bytes32 => ParamProposal) public proposals;

    IERC20 public token;
    PLCRVoting public voting;

    uint256 constant public PROCESSBY = 604800;

    //////////////////////////////////////////////////////////////// 
    /// Events                                                   ///
    ////////////////////////////////////////////////////////////////

    event ReparameterizationProposal(string name, uint256 value, bytes32 propId, uint256 deposit, uint256 appEndDate, address indexed proposer);

    event NewChallenge(bytes32 indexed propId, uint256 challengeID, uint256 commitEndDate, uint256 revealEndDate, address indexed challenger);

    event ProposalAccepted(bytes32 indexed propId, string name, uint256 value);

    event ProposalExpired(bytes32 indexed propId);

    event ChallengeSucceeded(bytes32 indexed propId, uint256 indexed challengeID, uint256 rewardPool, uint256 totalTokens);

    event ChallengeFailed(bytes32 indexed propId, uint256 indexed challengeID, uint256 rewardPool, uint256 totalTokens);

    event RewardClaimed(uint256 indexed challengeID, uint256 reward, address indexed voter);

    //////////////////////////////////////////////////////////////// 
    /// Errors                                                   ///
    ////////////////////////////////////////////////////////////////

    error Parameterizer_AddressZeroIsInvalidInput();

    error Parameterizer_ProposalExists();

    error Parameterizer_ValueHasNotChanged();

    error Parameterizer_ValueIsHigherThanOneHundred();

    error Parameterizer_TokenTransferFailed();

    error Parameterizer_ProposalDoesNotExistAndChallengeIdIsNotZero();

    error Parameterizer_ProposalHasNoChallengeAndAppExpiryDateAndProcessByDateHasNotPassed();

    error Parameterizer_DispensationPercentageIsOverOneHundred();

    error Parameterizer_DispensationPercentageInParameterizerIsOverOneHundred();

    error Parameterizer_VoterHasClaimedTokens();

    error Parameterizer_ChallengeHasNotBeenResolved();

    //////////////////////////////////////////////////////////////// 
    /// Constructor                                              ///
    ////////////////////////////////////////////////////////////////

    /**
    @dev Constructor. Can only be called once.
    @param _tokenAddr The address where the ERC20 token contract is deployed.
    @param _votingAddr The address where the PLCR voting contract is deployed.
    @param _parameters Array of canonical parameters.
    */
    constructor(address _tokenAddr, address _votingAddr, uint256[14] memory _parameters) {
        if (_tokenAddr == address(0)) revert Parameterizer_AddressZeroIsInvalidInput();
        if (_votingAddr == address(0)) revert Parameterizer_AddressZeroIsInvalidInput();

        token = IERC20(_tokenAddr);
        voting = PLCRVoting(_votingAddr);

        // minimum deposit for listing to be whitelisted
        _set("minDeposit", _parameters[0]);
        
        // minimum deposit to propose a reparameterization
        _set("pMinDeposit", _parameters[1]);

        // period over which applicants wait to be whitelisted
        _set("applyStageLen", _parameters[2]);

        // period over which reparmeterization proposals wait to be processed
        _set("pApplyStageLen", _parameters[3]);

        // length of commit period for voting
        _set("commitStageLen", _parameters[4]);
        
        // length of commit period for voting in parameterizer
        _set("pCommitStageLen", _parameters[5]);
        
        // length of reveal period for voting
        _set("revealStageLen", _parameters[6]);

        // length of reveal period for voting in parameterizer
        _set("pRevealStageLen", _parameters[7]);

        // percentage of losing party's deposit distributed to winning party
        _set("dispensationPct", _parameters[8]);

        // percentage of losing party's deposit distributed to winning party in parameterizer
        _set("pDispensationPct", _parameters[9]);

        // type of majority out of 100 necessary for candidate success
        _set("voteQuorum", _parameters[10]);

        // type of majority out of 100 necessary for proposal success in parameterizer
        _set("pVoteQuorum", _parameters[11]);

        // minimum length of time user has to wait to exit the registry 
        _set("exitTimeDelay", _parameters[12]);

        // maximum length of time user can wait to exit the registry
        _set("exitPeriodLen", _parameters[13]);
    }

    //////////////////////////////////////////////////////////////// 
    /// External Functions                                       ///
    ////////////////////////////////////////////////////////////////

    /**
    @notice For the provided proposal ID, set it, resolve its challenge, or delete it depending on whether it can be set, has a challenge which can be resolved, or if its "process by" date has passed.
    @param _propId The proposal ID to make a determination and state transition for.
    */
    function processProposal(bytes32 _propId) external {
        ParamProposal storage prop = proposals[_propId];
        address propOwner = prop.owner;
        uint256 propDeposit = prop.deposit;

        if (canBeSet(_propId)) {
            _set(prop.name, prop.value);

            emit ProposalAccepted(_propId, prop.name, prop.value);

            delete proposals[_propId];

            if (!token.transfer(propOwner, propDeposit)) revert Parameterizer_TokenTransferFailed();
        } else if (challengeCanBeResolved(_propId)) {
            _resolveChallenge(_propId);
        } else if (block.timestamp > prop.processBy) {
            emit ProposalExpired(_propId);

            delete proposals[_propId];

            if (!token.transfer(propOwner, propDeposit)) revert Parameterizer_TokenTransferFailed();
        } else {
            revert Parameterizer_ProposalHasNoChallengeAndAppExpiryDateAndProcessByDateHasNotPassed();
        }

        if (get("dispensationPct") > 100) revert Parameterizer_DispensationPercentageIsOverOneHundred();
        if (get("pDispensationPct") > 100) revert Parameterizer_DispensationPercentageInParameterizerIsOverOneHundred();

        delete proposals[_propId];
    }

    /**
    @dev Called by a voter to claim their rewards for each completed vote.
         Someone must call updateStatus() before this can be called.
    @param _challengeIDs The PLCR pollIDs of the challenges rewards are being claimed for.
    */
    function claimRewards(uint256[] calldata _challengeIDs) external {
        for (uint256 i = 0; i < _challengeIDs.length; i++) {
            claimReward(_challengeIDs[i]);
        }
    }

    /**
    @notice Propose a reparamaterization of the key _name's value to _value.
    @param _name The name of the proposed parameter to be set.
    @param _value The proposed value to set the parameter to be set.
    @return The proposal ID.
    */
    function proposeReparameterization(string calldata _name, uint256 _value) external returns (bytes32) {
        uint256 deposit = get("pMinDeposit");
        bytes32 propId = keccak256(abi.encodePacked(_name, _value));

        if (keccak256(abi.encodePacked(_name)) == keccak256(abi.encodePacked("dispensationPct")) ||
            keccak256(abi.encodePacked(_name)) == keccak256(abi.encodePacked("pDispensationPct"))) {
            if (_value > 100) revert Parameterizer_ValueIsHigherThanOneHundred();
        }

        if (propExists(propId)) revert Parameterizer_ProposalExists(); // Forbid duplicate proposals
        if (get(_name) == _value) revert Parameterizer_ValueHasNotChanged(); // Forbid NOOP reparameterizations

        // attach name and value to pollId
        proposals[propId] = ParamProposal({
            appExpiry: block.timestamp + get("pApplyStageLen"),
            challengeID: 0,
            deposit: deposit,
            name: _name,
            owner: msg.sender,
            processBy: block.timestamp + get("pApplyStageLen") + get("pCommitStageLen") + get("pRevealStageLen") + PROCESSBY,
            value: _value
        });

        if (!token.transferFrom(msg.sender, address(this), deposit)) revert Parameterizer_TokenTransferFailed();

        emit ReparameterizationProposal(_name, _value, propId, deposit, proposals[propId].appExpiry, msg.sender);

        return propId;
    }

    /**
    @notice Challenge the provided proposal ID, and put tokens at stake to do so.
    @param _propId The proposal ID to challenge.
    @return challengeID The challenge ID.
    */
    function challengeReparameterization(bytes32 _propId) external returns (uint256 challengeID) {
        ParamProposal memory prop = proposals[_propId];
        uint256 deposit = prop.deposit;

        if (!propExists(_propId) && prop.challengeID != 0) revert Parameterizer_ProposalDoesNotExistAndChallengeIdIsNotZero();

        uint256 pollId = voting.startPoll(
            get("pVoteQuorum"),
            get("pCommitStageLen"),
            get("pRevealStageLen")
        );

        Challenge storage challenge = challenges[pollId];

        challenge.challenger = msg.sender;
        challenge.rewardPool = 100 - get("pDispensationPct") * deposit / 100; // ???
        challenge.stake = deposit;
        challenge.resolved = false;
        challenge.winningTokens = 0;


        proposals[_propId].challengeID = pollId;

        if (!token.transferFrom(msg.sender, address(this), deposit)) revert Parameterizer_TokenTransferFailed();

        (uint256 commitEndDate, uint256 revealEndDate,,,) = voting.pollMap(pollId);

        emit NewChallenge(_propId, pollId, commitEndDate, revealEndDate, msg.sender);

        return pollId;
    }

    //////////////////////////////////////////////////////////////// 
    /// Public Functions                                         ///
    ////////////////////////////////////////////////////////////////

    /**
    @notice Claim the tokens owed for the msg.sender in the provided challenge.
    @param _challengeID The challenge ID to claim tokens for.
    */
    function claimReward(uint256 _challengeID) public {
        Challenge storage challenge = challenges[_challengeID];

        if (challenge.tokenClaims[msg.sender]) revert Parameterizer_VoterHasClaimedTokens();
        if (!challenge.resolved) revert Parameterizer_ChallengeHasNotBeenResolved();

        uint256 voterTokens = voting.getNumPassingTokens(msg.sender, _challengeID);
        uint256 reward = voterReward(msg.sender, _challengeID);

        challenge.winningTokens -= voterTokens;
        challenge.rewardPool -= reward;

        challenge.tokenClaims[msg.sender] = true;

        emit RewardClaimed(_challengeID, reward, msg.sender);

        if (!token.transfer(msg.sender, reward)) revert Parameterizer_TokenTransferFailed();
    }

    /**
    @dev Calculates the provided voter's token reward for the given poll.
    @param _voter The address of the voter whose reward balance is to be returned.
    @param _challengeID The ID of the challenge the voter's reward is being calculated for.
    @return The uint256 indicating the voter's reward.
    */
    function voterReward(address _voter, uint256 _challengeID) public view returns (uint256) {
        uint256 winningTokens = challenges[_challengeID].winningTokens;
        uint256 rewardPool = challenges[_challengeID].rewardPool;
        uint256 voterTokens = voting.getNumPassingTokens(_voter, _challengeID);

        return (voterTokens * rewardPool) / winningTokens;
    }

    /**
    @notice Determines whether a proposal passed its application stage without a challenge.
    @param _propId The proposal ID for which to determine whether its application stage passed without a challenge.
    */
    function canBeSet(bytes32 _propId) public view returns (bool) {
        ParamProposal memory prop = proposals[_propId];

        return (block.timestamp > prop.appExpiry && block.timestamp < prop.processBy && prop.challengeID == 0);
    }

    /**
    @notice Determines whether a proposal exists for the provided proposal ID.
    @param _propId The proposal ID whose existance is to be determined.
    */
    function propExists(bytes32 _propId) public view returns (bool) {
        return proposals[_propId].processBy > 0;
    }

    /**
    @notice Determines whether the provided proposal ID has a challenge which can be resolved.
    @param _propId The proposal ID whose challenge to inspect.
    */
    function challengeCanBeResolved(bytes32 _propId) public view returns (bool) {
        ParamProposal memory prop = proposals[_propId];
        Challenge storage challenge = challenges[prop.challengeID];

        return (prop.challengeID > 0 && challenge.resolved == false && voting.pollEnded(prop.challengeID));
    }

    /**
    @notice Determines the number of tokens to awarded to the winning party in a challenge.
    @param _challengeID The challengeID to determine a reward for.
    */
    function challengeWinnerReward(uint256 _challengeID) public view returns (uint256) {
        if(voting.getTotalNumberOfTokensForWinningOption(_challengeID) == 0) {
            // Edge case, nobody voted, give all tokens to the challenger.
            return 2 * challenges[_challengeID].stake;
        }

        return (2 * challenges[_challengeID].stake) - challenges[_challengeID].rewardPool;
    }

    /**
    @notice Getter for the parameter keyed by the provided name value.
    @param _name The key whose value is to be determined.
    */
    function get(string memory _name) public view returns (uint256 value) {
        return params[keccak256(abi.encodePacked(_name))];
    }

    /**
    @dev Getter for Challenge tokenClaims mappings.
    @param _challengeID The challengeID to query.
    @param _voter The voter whose claim status to query for the provided challengeID.
    */
    function tokenClaims(uint256 _challengeID, address _voter) public view returns (bool) {
        return challenges[_challengeID].tokenClaims[_voter];
    }

    //////////////////////////////////////////////////////////////// 
    /// Private Functions                                        ///
    ////////////////////////////////////////////////////////////////

    /**
    @dev Resolves a challenge for the provided _propId. It must be checked in advance whether the _propId has a challenge on it.
    @param _propId The proposal ID whose challenge is to be resolved.
    */
    function _resolveChallenge(bytes32 _propId) private {
        ParamProposal memory prop = proposals[_propId];
        Challenge storage challenge = challenges[prop.challengeID];

        uint256 reward = challengeWinnerReward(prop.challengeID);

        challenge.winningTokens = voting.getTotalNumberOfTokensForWinningOption(prop.challengeID);
        challenge.resolved = true;

        if (voting.isPassed(prop.challengeID)) {
            if(prop.processBy > block.timestamp) {
                _set(prop.name, prop.value);
            }

            emit ChallengeFailed(_propId, prop.challengeID, challenge.rewardPool, challenge.winningTokens);

            if (!token.transfer(prop.owner, reward)) revert Parameterizer_TokenTransferFailed();
        }
        else {
            emit ChallengeSucceeded(_propId, prop.challengeID, challenge.rewardPool, challenge.winningTokens);

            if (!token.transfer(challenges[prop.challengeID].challenger, reward)) revert Parameterizer_TokenTransferFailed();
        }
    }

    /**
    @dev Sets the parameter by the provided name to the provided value.
    @param _name The name of the parameter to be set.
    @param _value The value to set the parameter to be set.
    */
    function _set(string memory _name, uint256 _value) private {
        params[keccak256(abi.encodePacked(_name))] = _value;
    }
}
