// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

contract TaskPlatform {
    enum Status { Open, InProgress, Completed, Cancelled }

    struct Task {
        uint256 id;
        address poster;
        address worker;
        string title;
        string description;
        uint256 bounty;
        Status status;
    }

    uint256 public taskCount;
    mapping(uint256 => Task) public tasks;

    event TaskCreated(uint256 indexed id, address indexed poster, uint256 bounty);
    event TaskClaimed(uint256 indexed id, address indexed worker);
    event TaskCompleted(uint256 indexed id, address indexed worker, uint256 bounty);
    event TaskCancelled(uint256 indexed id);

    modifier onlyPoster(uint256 id) {
        require(msg.sender == tasks[id].poster, "Not poster");
        _;
    }

    modifier onlyWorker(uint256 id) {
        require(msg.sender == tasks[id].worker, "Not worker");
        _;
    }

    function createTask(string calldata title, string calldata description) external payable returns (uint256) {
        require(msg.value > 0, "Bounty required");
        uint256 id = ++taskCount;
        tasks[id] = Task(id, msg.sender, address(0), title, description, msg.value, Status.Open);
        emit TaskCreated(id, msg.sender, msg.value);
        return id;
    }

    function claimTask(uint256 id) external {
        Task storage t = tasks[id];
        require(t.status == Status.Open, "Not open");
        require(msg.sender != t.poster, "Poster cannot claim");
        t.worker = msg.sender;
        t.status = Status.InProgress;
        emit TaskClaimed(id, msg.sender);
    }

    function approveCompletion(uint256 id) external onlyPoster(id) {
        Task storage t = tasks[id];
        require(t.status == Status.InProgress, "Not in progress");
        t.status = Status.Completed;
        uint256 bounty = t.bounty;
        t.bounty = 0;
        (bool ok,) = t.worker.call{value: bounty}("");
        require(ok, "Transfer failed");
        emit TaskCompleted(id, t.worker, bounty);
    }

    function cancelTask(uint256 id) external onlyPoster(id) {
        Task storage t = tasks[id];
        require(t.status == Status.Open, "Can only cancel open tasks");
        t.status = Status.Cancelled;
        uint256 bounty = t.bounty;
        t.bounty = 0;
        (bool ok,) = t.poster.call{value: bounty}("");
        require(ok, "Refund failed");
        emit TaskCancelled(id);
    }

    function getTask(uint256 id) external view returns (Task memory) {
        return tasks[id];
    }
}
