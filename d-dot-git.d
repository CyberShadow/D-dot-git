module d_dot_git;

import std.algorithm;
import std.array;
import std.conv;
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

	Repository.History[string] histories;
	Hash[string][string] refs; // refs[refName][repoName]

	foreach (repoName, repo; repos)
	{
		stderr.writefln("Reading %s...", repo.path);
		histories[repoName] = repo.getHistory();
		foreach (name, hash; histories[repoName].refs)
			if (name.startsWith("refs/heads/"))
				continue;
			else
			if (name == "refs/remotes/origin/HEAD")
				continue;
			else
			if (name.startsWith("refs/remotes/origin/"))
				refs[name.replace("refs/remotes/origin/", "refs/heads/")][repoName] = hash;
			else
			if (name.startsWith("refs/tags/"))
				refs[name.replace("^{}", "")][repoName] = hash;
			else
				throw new Exception("Unknown ref kind: " ~ name);
	}

	if ("result".exists)
	{
		version (Windows)
			execute(["rm", "-rf", "result"]); // Git creates "read-only" files
		else
			rmdirRecurse("result");
	}
	mkdir("result");

	auto repo = new Repository("result");

	bool pretend = false;
	File f;
	ProcessPipes pipes;
	if (pretend)
		f = File("result/fast-import-data.txt", "wb");
	else
	{
		repo.gitRun("init", ".");
		pipes = pipeProcess(repo.argsPrefix ~ ["fast-import"], Redirect.stdin);
		f = pipes.stdin;
	}

	auto reReverseMerge = regex(`^Merge branch 'master' of github`);

	int[Hash[]] marks;
	int currentMark = 0;
	marks[null] = currentMark;

	foreach (refName, refHashes; refs)
	{
		static struct Merge
		{
			string repo;
			Commit* commit;
		}
		Merge[][string] repoMerges;
		Commit*[string] tags;

		// If a component doesn't have a branch, include their "master".
		// The alternative would be to create a whole new history
		// without that component, which would not be very useful.
		// However, we only need to include their history up to the latest
		// point in the tracked ref.

		auto latestTime = zip(refHashes.keys, refHashes.values)
			.map!(z => histories[z[0]].commits[z[1]].time)
			.reduce!max
		;

		foreach (repoName; repos.keys)
			if (repoName !in refHashes)
				refHashes[repoName] = refs["refs/heads/master"][repoName];

		foreach (repoName, refHash; refHashes)
		{
			auto history = histories[repoName];
			Merge[] merges;
			Commit* c = history.commits[refHash];
			do
			{
				merges ~= Merge(repoName, c);
				if (c.message.length && c.message[0].match(reReverseMerge))
				{
					enforce(c.parents.length == 2);
					c = c.parents[1];
				}
				else
					c = c.parents.length ? c.parents[0] : null;
			} while (c);
			repoMerges[repoName] = merges;
			//writefln("%d linear history commits in %s", linearHistory.length, repoName);
		}

		auto allMerges = repoMerges.values.join;
		allMerges.sort!(`a.commit.time > b.commit.time`, SwapStrategy.stable)();
		allMerges.reverse;
		auto end = allMerges.countUntil!(m => m.commit.time > latestTime);
		if (end >= 0)
			allMerges = allMerges[0..end];

		f.writefln("reset %s", refName);

		Hash[string] state;
		foreach (m; allMerges)
		{
			auto parentMark = marks[state.values.sort];
			state[m.repo] = m.commit.hash;

			if (state.values.sort in marks)
				continue;

			currentMark++;
			marks[state.values.sort.idup] = currentMark;

			f.writefln("commit %s", refName);
			f.writefln("mark :%d", currentMark);
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

			if (parentMark && parentMark != currentMark-1)
				f.writefln("from :%d", parentMark);

			foreach (name, hash; state)
				f.writefln("M 160000 %s %s", hash.toString(), name);

			f.writeln("M 644 inline .gitmodules");
			f.writeln("data <<DELIMITER");
			foreach (name, hash; state)
			{
				f.writefln("[submodule \"%s\"]", name);
				f.writefln("\tpath = %s", name);
				f.writefln("\turl = git://github.com/D-Programming-Language/%s", name);
			}
			f.writeln("DELIMITER");
			f.writeln();
		}

		f.writefln("reset %s", refName);
		f.writefln("from :%d", marks[state.values.sort]);

		currentMark++; // force explicit "from" for new refs
	}

	f.close();
	if (pretend)
		return;

	auto status = pipes.pid.wait();
	enforce(status == 0, "git-fast-import failed with status %d".format(status));

	repo.gitRun("reset", "--hard", "master");
	debug {} else
	{
		repo.gitRun("remote", "add", "origin", "ssh://git@bitbucket.org/cybershadow/d.git");
		repo.gitRun("push", "--mirror", "origin");
	}
}
