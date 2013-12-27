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
	Commit*[string] tags;

	foreach (name, repo; repos)
	{
		auto history = repo.getHistory("origin/master");
		Merge[] merges;
		Commit* c = history.commits[history.lastCommit];
		do
		{
			merges ~= Merge(name, c);
			c = c.parents.length ? c.parents[0] : null;
		} while (c);
		histories[name] = merges;
		//writefln("%d linear history commits in %s", linearHistory.length, name);

		foreach (tag, hash; history.tags)
			if (tag !in tags || tags[tag].time < history.commits[hash].time)
				tags[tag] = history.commits[hash];
	}

	auto allHistory = histories.values.join;
	allHistory.sort!`a.commit.time > b.commit.time`();
	allHistory.reverse;

	string[][Hash] tagPoints;
	foreach (tag, commit; tags)
		tagPoints[commit.hash] ~= tag;

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
	bool[string] emittedTags;
	foreach (n, m; allHistory)
	{
		state[m.repo] = m.commit.hash;

		f.writeln("commit refs/heads/master");
		f.writefln("mark :%d", n+1);
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

		foreach (tag; tagPoints.get(m.commit.hash, null))
		{
			f.writefln("reset refs/tags/%s", tag);
			f.writefln("from :%d", n+1);
		}
	}
	f.close();
	auto status = pipes.pid.wait();
	enforce(status == 0, "git-fast-import failed with status %d".format(status));

	repo.gitRun("reset", "--hard", "master");
	debug {} else
	{
		repo.gitRun("remote", "add", "origin", "ssh://git@bitbucket.org/cybershadow/d.git");
		repo.gitRun("push", "--force", "--tags", "--set-upstream", "origin", "master");
	}
}
