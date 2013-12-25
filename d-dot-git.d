module d_dot_git;

import std.algorithm;
import std.array;
import std.exception;
import std.file;
import std.path;
import std.process;
import std.range;
import std.regex;
import std.stdio;
import std.string;
import std.parallelism;

import repo;

Repository[string] repos;

void main()
{
	foreach (de; dirEntries("repos", SpanMode.shallow))
		repos[de.name.baseName] = new Repository(de.name);

	debug {} else
	foreach (repo; repos.values.parallel)
	{
		stderr.writefln("Fetching %s...", repo.path);
		repo.gitRun("fetch", "origin");
		stderr.writefln("Done fetching %s.", repo.path);
	}

	static struct Merge
	{
		string repo;
		Commit* commit;
	}
	Merge[][string] histories;

	foreach (name, repo; repos)
	{
		auto history = repo.getHistory();
		Merge[] merges;
		Commit* c = history.commits[history.lastCommit];
		merges ~= Merge(name, c);
		while (c.parents.length)
		{
			c = c.parents[0];
			merges ~= Merge(name, c);
		}
		histories[name] = merges;
		//writefln("%d linear history commits in %s", linearHistory.length, name);
	}

	auto allHistory = histories.values.join;
	allHistory.sort!`a.commit.time > b.commit.time`();
	allHistory.reverse;

	if ("result".exists)
	{
		version (Windows)
			execute(["rm", "-rf", "result"]); // Git creates "read-only" files
		else
			rmdirRecurse("result");
	}
	mkdir("result");

	auto repo = new Repository("result");
	repo.gitRun("init", ".");

	//auto f = File("result/fast-import-data.txt", "wb");
	auto pipes = pipeProcess(repo.argsPrefix ~ ["fast-import"], Redirect.stdin);
	auto f = pipes.stdin;

	f.writeln("reset refs/heads/master");

	Hash[string] state;
	foreach (m; allHistory)
	{
		state[m.repo] = m.commit.hash;

		f.writeln("commit refs/heads/master");
		f.writefln("author %s", m.commit.author);
		f.writefln("committer %s", m.commit.committer);

		string[] messageLines = m.commit.message;
		if (messageLines.length)
		{
			// Add a link to the pull request
			auto pullMatch = messageLines[0].match(`^Merge pull request #(\d+) from `);
			if (pullMatch)
			{
				size_t p;
				while (p < messageLines.length && messageLines[p].length)
					p++;
				messageLines = messageLines[0..p] ~ ["", "https://github.com/D-Programming-Language/%s/pull/%s".format(m.repo, pullMatch.captures[1])] ~ messageLines[p..$];
			}
		}

		auto message = "%s: %s".format(m.repo, messageLines.join("\n"));
		f.writefln("data %s", message.length);
		f.writeln(message);

		foreach (name, hash; state)
			f.writefln("M 160000 %s %s", hash.toString(), name);

		f.writeln("M 644 inline .gitmodules");
		f.writeln("data <<DELIMITER");
		foreach (name, hash; state)
		{
			f.writefln("[submodule \"%s\"]", name);
			f.writefln("\tpath = %s", name);
			f.writefln("\turl = https://github.com/D-Programming-Language/%s", name);
		}
		f.writeln("DELIMITER");

		f.writeln();
	}
	f.close();
	auto status = pipes.pid.wait();
	enforce(status == 0, "git-fast-import failed with status %d".format(status));

	repo.gitRun("reset", "--hard", "master");
	repo.gitRun("remote", "add", "origin", "git@github.com:CyberShadow-D/D.git");
	repo.gitRun("push", "--force", "--set-upstream", "origin", "master");
}
