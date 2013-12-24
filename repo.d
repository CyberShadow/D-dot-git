module repo;

import std.algorithm;
import std.conv;
import std.exception;
import std.file;
import std.format;
import std.path;
import std.process;
import std.range;
import std.string;

class Repository
{
	string path;
	string[] argsPrefix;

	this(string path)
	{
		enforce(path.exists, "Repository path does not exist");
		//enforce(path.buildPath(".git").exists, "Repository has no .git");
		this.path = path;
		this.argsPrefix = [`git`, `--work-tree=` ~ path, `--git-dir=` ~ path.buildPath(".git")];
	}

	void gitRun(string[] args...)
	{
		auto status = spawnProcess(argsPrefix ~ args).wait();
		enforce(status == 0, "Git command %s failed with status %d".format(args, status));
	}

	string gitQuery(string[] args...)
	{
		auto result = execute(argsPrefix ~ args);
		enforce(result.status == 0, "Git command %s failed with status %d".format(args, result.status));
		return result.output;
	}

	// --------------------------------------------------------------------------------------------------------------
	
	static struct History
	{
		Commit*[Hash] commits;
		uint numCommits = 0;
		Hash lastCommit;
	}

	History getHistory()
	{
		History history;

		Commit* getCommit(Hash hash)
		{
			auto pcommit = hash in history.commits;
			return pcommit ? *pcommit : (history.commits[hash] = new Commit(history.numCommits++, hash));
		}

		Commit* commit;

		foreach (line; gitQuery([`log`, `master`, `--pretty=raw`]).splitLines())
		{
			if (!line.length)
				continue;

			if (line.startsWith("commit "))
			{
				auto hash = line[7..$].toCommitHash();
				if (!history.numCommits)
					history.lastCommit = hash;
				commit = getCommit(hash);
			}
			else
			if (line.startsWith("tree "))
				continue;
			else
			if (line.startsWith("parent "))
			{
				auto hash = line[7..$].toCommitHash();
				auto parent = getCommit(hash);
				commit.parents ~= parent;
				parent.children ~= commit;
			}
			else
			if (line.startsWith("author "))
				commit.author = line[7..$];
			else
			if (line.startsWith("committer "))
			{
				commit.committer = line[10..$];
				commit.time = line.split(" ")[$-2].to!int();
			}
			else
			if (line.startsWith("    "))
				commit.message ~= line[4..$];
			else
				//enforce(false, "Unknown line in git log: " ~ line);
				commit.message[$-1] ~= line;
		}

		return history;
	}
}

alias ubyte[20] Hash;

struct Commit
{
	uint id;
	Hash hash;
	uint time;
	string author, committer;
	string[] message;
	Commit*[] parents, children;
}

Hash toCommitHash(string hash)
{
	enforce(hash.length == 40, "Bad hash length");
	ubyte[20] result;
	foreach (i, ref b; result)
		b = to!ubyte(hash[i*2..i*2+2], 16);
	return result;
}

string toString(ref Hash hash)
{
	return format("%(%02x%)", hash[]);
}

unittest
{
	assert(toCommitHash("0123456789abcdef0123456789ABCDEF01234567") == [0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF, 0x01, 0x23, 0x45, 0x67]);
}
