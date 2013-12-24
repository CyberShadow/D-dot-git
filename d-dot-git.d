module d_dot_git;

import std.algorithm;
import std.array;
import std.file;
import std.path;
import std.process;
import std.range;
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
		//rmdirRecurse("result");
		execute(["rm", "-rf", "result"]);
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
		auto message = "%s: %s".format(m.repo, m.commit.message.join("\n"));
		f.writefln("data %s", message.length);
		f.writeln(message);
		foreach (name, hash; state)
			f.writefln("M 160000 %s %s", hash.toString(), name);
		f.writeln();
	}
	f.close();
	pipes.pid.wait();

	repo.gitRun("reset", "--hard", "master");
}
