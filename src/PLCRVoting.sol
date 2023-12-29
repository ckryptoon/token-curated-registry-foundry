// SPDX-License-Identifier: MIT

pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {DLL} from "./utils/DLL.sol";
import {AttributeStore} from "./utils/AttributeStore.sol";

/**
 * @title PLCRVoting
 * @author Casper Kjær Rasmussen / @ckryptoon
 * @notice This is the PLCR (Partial-Lock Commit-Reveal) voting contract you need to build a TCR (Token Curated Registry).
 */
contract PLCRVoting {
    //////////////////////////////////////////////////////////////// 
    /// Types                                                    ///
    ////////////////////////////////////////////////////////////////
    using AttributeStore for AttributeStore.Data;
    using DLL for DLL.Data;

    struct Poll {
        uint256 commitEndDate;
        uint256 revealEndDate;
        uint256 voteQuorum;
        uint256 votesFor;
        uint256 votesAgainst;
        mapping(address => bool) didCommit;
        mapping(address => bool) didReveal;
        mapping(address => uint256) voteOptions;
    }

    //////////////////////////////////////////////////////////////// 
    /// State Variables                                          ///
    ////////////////////////////////////////////////////////////////

    uint256 public pollNonce;

    mapping(uint256 => Poll) public pollMap;

    mapping(address => uint256) public voteTokenBalance;

    mapping(address => DLL.Data) dllMap;

    AttributeStore.Data store;

    IERC20 public token;

    //////////////////////////////////////////////////////////////// 
    /// Events                                                   ///
    ////////////////////////////////////////////////////////////////

    event VoteCommitted(uint256 indexed pollId, uint256 amount, address indexed voter);

    event VoteRevealed(uint256 indexed pollId, uint256 amount, uint256 votesFor, uint256 votesAgainst, uint256 indexed choice, address indexed voter, uint256 salt);

    event PollCreated(uint256 voteQuorum, uint256 commitEndDate, uint256 revealEndDate, uint256 indexed pollId, address indexed creator);

    event VotingRightsGranted(uint256 amount, address indexed voter);

    event VotingRightsWithdrawn(uint256 amount, address indexed voter);

    event TokensRescued(uint256 indexed pollId, address indexed voter);

    //////////////////////////////////////////////////////////////// 
    /// Errors                                                   ///
    ////////////////////////////////////////////////////////////////

    error PLCRVoting_AddressZeroIsInvalidInput();

    error PLCRVoting_InsufficientFunds();

    error PLCRVoting_TokenTransferFailed();

    error PLCRVoting_AmountIsHigherThanAvailableTokens();

    error PLCRVoting_RevealPeriodHasNotExpired();

    error PLCRVoting_DoublyLinkedListMappingAtCallerContainspollId();

    error PLCRVoting_CommitPeriodIsNotActive();

    error PLCRVoting_AmountIsHigherThanVoteTokenBalance();

    error PLCRVoting_pollIdIsZero();

    error PLCRVoting_SecretHashIsZero();

    error PLCRVoting_PreviouspollIdExistsOrIsNotEqualToZero();

    error PLCRVoting_CallerAndAmountIsNotInValidPosition();

    error PLCRVoting_InvalidpollIdsOrSecretHashesLength();

    error PLCRVoting_InvalidpollIdsOrAmountsLength();

    error PLCRVoting_InvalidpollIdsOrPreviouspollIdsLength();

    error PLCRVoting_RevealPeriodHasExpired();

    error PLCRVoting_CallerHasNotCommittedVote();

    error PLCRVoting_CallerHasAlreadyRevealed();

    error PLCRVoting_InvalidpollIdsLengthOrVoteOptionsLength();

    error PLCRVoting_InvalidpollIdsLengthOrSaltsLength();

    error PLCRVoting_PollHasNotEnded();

    error PLCRVoting_VoterHasNotRevealed();

    error PLCRVoting_VoterRevealedButNotInMajority();

    error PLCRVoting_PollDoesNotExist();

    //////////////////////////////////////////////////////////////// 
    /// Constructor                                              ///
    ////////////////////////////////////////////////////////////////

    /**
    @dev Constructor. Can only be called once.
    @param _tokenAddr The address where the ERC20 token contract is deployed.
    */
    constructor(address _tokenAddr) {
        if (_tokenAddr == address(0)) revert PLCRVoting_AddressZeroIsInvalidInput();

        token = IERC20(_tokenAddr);
    }

    //////////////////////////////////////////////////////////////// 
    /// External Functions                                       ///
    ////////////////////////////////////////////////////////////////

    /**
    @notice Withdraw _amount ERC20 tokens from the voting contract, revoking these voting rights.
    @param _amount The number of ERC20 tokens desired in exchange for voting rights.
    */
    function withdrawVotingRights(uint256 _amount) external {
        uint256 availableTokens = voteTokenBalance[msg.sender] - getLockedTokens(msg.sender);

        if (availableTokens < _amount) revert PLCRVoting_AmountIsHigherThanAvailableTokens();

        voteTokenBalance[msg.sender] -= _amount;

        if (!token.transfer(msg.sender, _amount)) revert PLCRVoting_TokenTransferFailed();

        emit VotingRightsWithdrawn(_amount, msg.sender);
    }

    /**
    @dev Unlocks tokens locked in unrevealed votes where polls have ended
    @param _pollIds Array of integer identifiers associated with the target polls
    */
    function rescueTokensInMultiplePolls(uint256[] calldata _pollIds) external {
        for (uint256 i = 0; i < _pollIds.length; i++) {
            rescueTokens(_pollIds[i]);
        }
    }

    /**
    @notice Commits votes using hashes of choices and secret salts to conceal votes until reveal.
    @param _pollIds Array of integer identifiers associated with target polls.
    @param _secretHashes Array of commit keccak256 hashes of voter's choices and salts (tightly packed in this order).
    @param _amounts Array of numbers of tokens to be committed towards the target polls.
    @param _prevpollIds Array of IDs of the polls that the user has voted the maximum number of tokens in which is still less than or equal to amount.
    */
    function commitVotes(uint256[] calldata _pollIds, bytes32[] calldata _secretHashes, uint256[] calldata _amounts, uint256[] calldata _prevpollIds) external {
        if (_pollIds.length != _secretHashes.length) revert PLCRVoting_InvalidpollIdsOrSecretHashesLength();
        if (_pollIds.length != _amounts.length) revert PLCRVoting_InvalidpollIdsOrAmountsLength();
        if (_pollIds.length != _prevpollIds.length) revert PLCRVoting_InvalidpollIdsOrPreviouspollIdsLength();

        for (uint256 i = 0; i < _pollIds.length; i++) {
            commitVote(_pollIds[i], _secretHashes[i], _amounts[i], _prevpollIds[i]);
        }
    }

    /**
    @notice             Reveals multiple votes with choices and secret salts used in generating commitHashes to attribute committed tokens
    @param _pollIds     Array of integer identifiers associated with target polls
    @param _voteOptions Array of vote choices used to generate commitHashes for associated polls
    @param _salts       Array of secret numbers used to generate commitHashes for associated polls
    */
    function revealVotes(uint256[] calldata _pollIds, uint256[] calldata _voteOptions, uint256[] calldata _salts) external {
        if (_pollIds.length != _voteOptions.length) revert PLCRVoting_InvalidpollIdsLengthOrVoteOptionsLength();
        if (_pollIds.length != _salts.length) revert PLCRVoting_InvalidpollIdsLengthOrSaltsLength();

        for (uint256 i = 0; i < _pollIds.length; i++) {
            revealVote(_pollIds[i], _voteOptions[i], _salts[i]);
        }
    }

    /**
    @dev Initiates a poll with canonical configured parameters at pollID emitted by PollCreated event.
    @param _voteQuorum Type of majority (out of 100) that is necessary for poll to be successful.
    @param _commitDuration Length of desired commit period in seconds.
    @param _revealDuration Length of desired reveal period in seconds.
    */
    function startPoll(uint256 _voteQuorum, uint256 _commitDuration, uint256 _revealDuration) external returns (uint256 pollID) {
        pollNonce = pollNonce + 1;

        uint256 commitEndDate = block.timestamp + _commitDuration;
        uint256 revealEndDate = commitEndDate + _revealDuration;

        Poll storage poll = pollMap[pollNonce];

        poll.voteQuorum = _voteQuorum;
        poll.commitEndDate = _commitDuration;
        poll.votesFor = 0;
        poll.votesAgainst = 1;

        emit PollCreated(_voteQuorum, commitEndDate, revealEndDate, pollNonce, msg.sender);
        
        return pollNonce;
    }

    //////////////////////////////////////////////////////////////// 
    /// Public Functions                                         ///
    ////////////////////////////////////////////////////////////////

    /**
    @notice Loads _amount ERC20 tokens into the voting contract for one-to-one voting rights.
    @dev Assumes that msg.sender has approved voting contract to spend on their behalf.
    @param _amount The number of votingTokens desired in exchange for ERC20 tokens.
    */
    function requestVotingRights(uint256 _amount) public {
        if (token.balanceOf(msg.sender) < _amount) revert PLCRVoting_InsufficientFunds();

        voteTokenBalance[msg.sender] += _amount;

        if (!token.transferFrom(msg.sender, address(this), _amount)) revert PLCRVoting_TokenTransferFailed();

        emit VotingRightsGranted(_amount, msg.sender);
    }

    /**
    @dev Unlocks tokens locked in unrevealed vote where poll has ended
    @param _pollId Integer identifier associated with the target poll
    */
    function rescueTokens(uint256 _pollId) public {
        if (!isExpired(pollMap[_pollId].revealEndDate)) revert PLCRVoting_RevealPeriodHasNotExpired();
        if (!dllMap[msg.sender].contains(_pollId)) revert PLCRVoting_DoublyLinkedListMappingAtCallerContainspollId();

        dllMap[msg.sender].remove(_pollId);

        emit TokensRescued(_pollId, msg.sender);
    }

    /**
    @notice Commits vote using hash of choice and secret salt to conceal vote until reveal.
    @param _pollId Integer identifier associated with target poll.
    @param _secretHash Commit keccak256 hash of voter's choice and salt (tightly packed in this order).
    @param _amount The number of tokens to be committed towards the target poll.
    @param _prevpollId The ID of the poll that the user has voted the maximum number of tokens in which is still less than or equal to amount.
    */
    function commitVote(uint256 _pollId, bytes32 _secretHash, uint256 _amount, uint256 _prevpollId) public {
        if (!commitPeriodActive(_pollId)) revert PLCRVoting_CommitPeriodIsNotActive();

        if (voteTokenBalance[msg.sender] < _amount) {
            uint256 remainder = _amount - voteTokenBalance[msg.sender];
            requestVotingRights(remainder);
        }

        if (voteTokenBalance[msg.sender] < _amount) revert PLCRVoting_AmountIsHigherThanVoteTokenBalance();
        if (_pollId == 0) revert PLCRVoting_pollIdIsZero();
        if (_secretHash == 0) revert PLCRVoting_SecretHashIsZero();
        if (_prevpollId != 0 || dllMap[msg.sender].contains(_prevpollId)) revert PLCRVoting_PreviouspollIdExistsOrIsNotEqualToZero();

        uint256 nextpollId = dllMap[msg.sender].getNext(_prevpollId);

        if (nextpollId == _pollId) {
            nextpollId = dllMap[msg.sender].getNext(_pollId);
        }

        if (!validPosition(_prevpollId, nextpollId, msg.sender, _amount)) revert PLCRVoting_CallerAndAmountIsNotInValidPosition();
        dllMap[msg.sender].insert(_prevpollId, _pollId, nextpollId);

        bytes32 uuid = attrUuid(msg.sender, _pollId);

        store.setAttribute(uuid, "amount", _amount);
        store.setAttribute(uuid, "commitHash", uint256(_secretHash));

        pollMap[_pollId].didCommit[msg.sender] = true;

        emit VoteCommitted(_pollId, _amount, msg.sender);
    }

    /**
    @notice Reveals vote with choice and secret salt used in generating commitHash to attribute committed tokens
    @param _pollId Integer identifier associated with target poll
    @param _voteOption Vote choice used to generate commitHash for associated poll
    @param _salt Secret number used to generate commitHash for associated poll
    */
    function revealVote(uint256 _pollId, uint256 _voteOption, uint256 _salt) public {
        // Make sure the reveal period is active
        if (!revealPeriodActive(_pollId)) revert PLCRVoting_RevealPeriodHasExpired();
        if (!pollMap[_pollId].didCommit[msg.sender]) revert PLCRVoting_CallerHasNotCommittedVote(); // make sure user has committed a vote for this poll
        if (pollMap[_pollId].didReveal[msg.sender]) revert PLCRVoting_CallerHasAlreadyRevealed(); // prevent user from revealing multiple times
        require(keccak256(abi.encodePacked(_voteOption, _salt)) == getCommitHash(msg.sender, _pollId)); // compare resultant hash from inputs to original commitHash

        uint256 amount = getAmount(msg.sender, _pollId);

        if (_voteOption == 1) {// apply amount to appropriate poll choice
            pollMap[_pollId].votesFor += amount;
        } else {
            pollMap[_pollId].votesAgainst += amount;
        }

        dllMap[msg.sender].remove(_pollId); // remove the node referring to this vote upon reveal
        pollMap[_pollId].didReveal[msg.sender] = true;
        pollMap[_pollId].voteOptions[msg.sender] = _voteOption;

        emit VoteRevealed(_pollId, amount, pollMap[_pollId].votesFor, pollMap[_pollId].votesAgainst, _voteOption, msg.sender, _salt);
    }

    /**
    @dev Compares previous and next poll's committed tokens for sorting purposes
    @param _prevID Integer identifier associated with previous poll in sorted order
    @param _nextID Integer identifier associated with next poll in sorted order
    @param _voter Address of user to check DLL position for
    @param _amount The number of tokens to be committed towards the poll (used for sorting)
    @return valid Boolean indication of if the specified position maintains the sort
    */
    function validPosition(uint256 _prevID, uint256 _nextID, address _voter, uint256 _amount) public view returns (bool valid) {
        bool prevValid = (_amount >= getAmount(_voter, _prevID));
        bool nextValid = (_amount <= getAmount(_voter, _nextID) || _nextID == 0);

        return prevValid && nextValid;
    }

    /**
    @param _voter Address of voter who voted in the majority bloc.
    @param _pollId Integer identifier associated with target poll.
    @return correctVotes Number of tokens voted for winning option.
    */
    function getNumPassingTokens(address _voter, uint256 _pollId) public view returns (uint256 correctVotes) {
        if (!pollEnded(_pollId)) revert PLCRVoting_PollHasNotEnded();
        if (!pollMap[_pollId].didReveal[_voter]) revert PLCRVoting_VoterHasNotRevealed();

        uint256 winningChoice = isPassed(_pollId) ? 1 : 0;
        uint256 voterVoteOption = pollMap[_pollId].voteOptions[_voter];

        if (voterVoteOption != winningChoice) revert PLCRVoting_VoterRevealedButNotInMajority();

        return getAmount(_voter, _pollId);
    }

    /**
    @notice Determines if proposal has passed.
    @dev Check if votesFor out of totalVotes exceeds votesQuorum (requires pollEnded).
    @param _pollId Integer identifier associated with target poll.
    */
    function isPassed(uint256 _pollId) public view returns (bool passed) {
        if (!pollEnded(_pollId)) revert PLCRVoting_PollDoesNotExist();

        Poll storage poll = pollMap[_pollId];

        return (100 * poll.votesFor) > (poll.voteQuorum * (poll.votesFor + poll.votesAgainst));
    }

    /**
    @dev Gets the total winning votes for reward distribution purposes.
    @param _pollId Integer identifier associated with target poll.
    @return amount Total number of votes committed to the winning option for specified poll.
    */
    function getTotalNumberOfTokensForWinningOption(uint256 _pollId) public view returns (uint256 amount) {
        require(pollEnded(_pollId));

        if (isPassed(_pollId))
            return pollMap[_pollId].votesFor;
        else
            return pollMap[_pollId].votesAgainst;
    }

    /**
    @notice Determines if poll is over.
    @dev Checks isExpired for specified poll's revealEndDate.
    @return ended Boolean indication of whether polling period is over.
    */
    function pollEnded(uint256 _pollId) public view returns (bool ended) {
        if (!pollExists(_pollId)) revert PLCRVoting_PollDoesNotExist();

        return isExpired(pollMap[_pollId].revealEndDate);
    }

    /**
    @notice Checks if the commit period is still active for the specified poll.
    @dev Checks isExpired for the specified poll's commitEndDate.
    @param _pollId Integer identifier associated with target poll.
    @return active Boolean indication of isCommitPeriodActive for target poll.
    */
    function commitPeriodActive(uint256 _pollId) public view returns (bool active) {
        if (!pollExists(_pollId)) revert PLCRVoting_PollDoesNotExist();

        return !isExpired(pollMap[_pollId].commitEndDate);
    }

    /**
    @notice Checks if the reveal period is still active for the specified poll.
    @dev Checks isExpired for the specified poll's revealEndDate.
    @param _pollId Integer identifier associated with target poll.
    */
    function revealPeriodActive(uint256 _pollId) public view returns (bool active) {
        require(pollExists(_pollId));

        return !isExpired(pollMap[_pollId].revealEndDate) && !commitPeriodActive(_pollId);
    }

    /**
    @dev Checks if user has committed for specified poll.
    @param _voter Address of user to check against.
    @param _pollId Integer identifier associated with target poll.
    @return committed Boolean indication of whether user has committed.
    */
    function didCommit(address _voter, uint256 _pollId) public view returns (bool committed) {
        if (!pollExists(_pollId)) revert PLCRVoting_PollDoesNotExist();

        return pollMap[_pollId].didCommit[_voter];
    }

    /**
    @dev Checks if user has revealed for specified poll.
    @param _voter Address of user to check against.
    @param _pollId Integer identifier associated with target poll.
    @return revealed Boolean indication of whether user has revealed.
    */
    function didReveal(address _voter, uint256 _pollId) public view returns (bool revealed) {
        if (!pollExists(_pollId)) revert PLCRVoting_PollDoesNotExist();

        return pollMap[_pollId].didReveal[_voter];
    }

    /**
    @dev Checks if a poll exists.
    @param _pollId The pollId whose existance is to be evaluated.
    @return exists Boolean Indicates whether a poll exists for the provided pollId.
    */
    function pollExists(uint256 _pollId) public view returns (bool exists) {
        return (_pollId != 0 && _pollId <= pollNonce);
    }

    /**
    @dev Gets the bytes32 commitHash property of target poll.
    @param _voter Address of user to check against.
    @param _pollId Integer identifier associated with target poll.
    @return commitHash Bytes32 hash property attached to target poll.
    */
    function getCommitHash(address _voter, uint256 _pollId) public view returns (bytes32 commitHash) {
        return bytes32(store.getAttribute(attrUuid(_voter, _pollId), "commitHash"));
    }

    /**
    @dev Wrapper for getAttribute with attrName="amount".
    @param _voter Address of user to check against.
    @param _pollId Integer identifier associated with target poll.
    @return amount Number of tokens committed to poll in sorted poll-linked-list.
    */
    function getAmount(address _voter, uint256 _pollId) public view returns (uint256 amount) {
        return store.getAttribute(attrUuid(_voter, _pollId), "amount");
    }

    /**
    @dev Gets top element of sorted poll-linked-list.
    @param _voter Address of user to check against.
    @return pollId Integer identifier to poll with maximum number of tokens committed to it.
    */
    function getLastNode(address _voter) public view returns (uint256 pollId) {
        return dllMap[_voter].getPrev(0);
    }

    /**
    @dev Gets the amount property of getLastNode.
    @param _voter Address of user to check against.
    @return amount Maximum number of tokens committed in poll specified.
    */
    function getLockedTokens(address _voter) public view returns (uint256 amount) {
        return getAmount(_voter, getLastNode(_voter));
    }

    /**
     * @dev Takes the last node in the user's DLL and iterates backwards through the list searching for a node with a value less than or equal to the provided _amount value. When such a node is found, if the provided _pollId matches the found nodeId, this operation is an in-place update. In that case, return the previous node of the node being updated. Otherwise  return the first node that was found with a value less than or equal to the provided _amount.
     * @param _voter The voter whose DLL will be searched.
     * @param _amount The value for the amount attribute in the node to be inserted.
     * @return prevNode The node ID of the previous node.
     */
    function getInsertPointForamount(address _voter, uint256 _amount, uint256 _pollId) public view returns (uint256 prevNode) {
        uint256 nodeId = getLastNode(_voter);
        uint256 tokensInNode = getAmount(_voter, nodeId);

        while(nodeId != 0) {
            tokensInNode = getAmount(_voter, nodeId);
            if(tokensInNode <= _amount) {
                if(nodeId == _pollId) {
                    nodeId = dllMap[_voter].getPrev(nodeId);
                }
                return nodeId; 
            }

            nodeId = dllMap[_voter].getPrev(nodeId);
        }

        return nodeId;
    }

    /**
    @dev Checks if an expiration date has been reached.
    @param _terminationDate Integer timestamp of date to compare current timestamp with.
    @return expired Boolean indication of whether the terminationDate has passed.
    */
    function isExpired(uint256 _terminationDate) public view returns (bool expired) {
        return (block.timestamp > _terminationDate);
    }

    /**
    @dev Generates an identifier which associates a user and a poll together.
    @param _pollId Integer identifier associated with target poll.
    @return uuid Hash which is deterministic from _user and _pollId.
    */
    function attrUuid(address _user, uint256 _pollId) public pure returns (bytes32 uuid) {
        return keccak256(abi.encodePacked(_user, _pollId));
    }
}
