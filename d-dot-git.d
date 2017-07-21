module d_dot_git;

import std.algorithm;
import std.array;
import std.conv;
import std.exception;
import std.file;
import std.functional;
import std.path;
import std.process;
import std.range;
import std.regex;
import std.stdio;
import std.string;
import std.parallelism;
import std.typecons;

import ae.utils.array;
import ae.utils.regex;

import repo;

Repository[string] repos;

enum gitUrlRoot = "https://github.com/dlang/";
immutable repoNames = ["dmd", "druntime", "phobos", "tools", "installer", "dlang.org"];

void main()
{
	foreach (name; repoNames)
	{
		auto path = buildPath("repos", name);
		if (!path.exists)
			enforce(spawnProcess(["git", "clone", "--mirror", gitUrlRoot ~ name, path]).wait() == 0, "git clone failed");
		repos[name] = new Repository(path);
	}

	debug
		stderr.writeln("Not fetching in debug build.");
	else
	foreach (repo; repos.values.parallel)
	{
		stderr.writefln("Fetching %s...", repo.path);
		repo.gitRun("fetch", "--prune", "origin");
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
				refs[name][repoName] = hash;
			else
			if (name.startsWith("refs/tags/"))
				refs[name.replace("^{}", "")][repoName] = hash;
			else
			if (name.startsWith("refs/pull/"))
				continue;
			else
			if (name.startsWith("refs/remotes/"))
				continue;
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

	int currentMark = 0;

	foreach (refName, refHashes; refs)
	{
		int[Hash[]] marks;
		marks[null] = currentMark;

		static struct Merge
		{
			string repo;
			Commit* commit;
		}
		Merge[][string] repoMerges;

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
			auto branchName =
				refName.startsWith("refs/heads/") ? refName.split("/")[$-1] :
				refName.startsWith("refs/tags/v") ? "stable" :
				"master";
			Merge[] merges;
			Commit* c = history.commits[refHash];
			do
			{
				merges ~= Merge(repoName, c);
				auto subject = c.message.length ? c.message[0] : null;
				if (subject.startsWith("Merge branch 'master' of github"))
				{
					enforce(c.parents.length == 2);
					c = c.parents[1];
				}
				else
				if (c.parents.length == 2 && subject.startsWith("Merge pull request #"))
				{
					if (subject.endsWith("/merge_" ~ branchName))
					{
						// We have lost our way and are on the wrong
						// branch, but we can get back on our branch
						// here
						c = c.parents[1];
					}
					else
						c = c.parents[0];
				}
				else
				if (c.parents.length == 2 && subject.skipOver("Merge remote-tracking branch 'upstream/master' into "))
				{
					bool ourBranch = subject == branchName;
					c = c.parents[ourBranch ? 0 : 1];
				}
				else
				if (c.parents.length == 2 && subject.skipOver("Merge remote-tracking branch 'upstream/"))
				{
					subject = subject.chomp(" into merge_" ~ branchName);
					bool ourBranch = subject == branchName ~ "'";
					c = c.parents[ourBranch ? 1 : 0];
				}
				else
				if (c.parents.length > 1)
				{
					enforce(c.parents.length == 2, "Octopus merge");

					// Approximately equivalent to git-merge-base
					static const(Commit)*[] commonParents(in Commit*[] commits) pure
					{
						bool[Commit*][] seen;
						seen.length = commits.length;

						foreach (index, parentCommit; commits)
						{
							auto queue = [parentCommit];
							while (!queue.empty)
							{
								auto commit = queue.front;
								queue.popFront;
								foreach (parent; commit.parents)
								{
									if (parent in seen[index])
										continue;
									seen[index][parent] = true;
									queue ~= parent;
								}
							}
						}

						bool[Commit*] commonParents =
							seen[0]
							.byKey
							.filter!(commit => seen.all!(s => commit in s))
							.map!(commit => tuple(commit, true))
							.assocArray;

						foreach (parent; commonParents.keys)
						{
							if (parent !in commonParents)
								continue; // already removed

							auto queue = parent.parents[];
							while (!queue.empty)
							{
								auto commit = queue.front;
								queue.popFront;
								if (commit in commonParents)
								{
									commonParents.remove(commit);
									queue ~= commit.parents;
								}
							}
						}

						return commonParents.keys;
					}

					static const(Commit)*[] commonParentsOfMerge(Commit* merge) pure
					{
						return commonParents(merge.parents);
					}

					static const(Commit)*[] commitsBetween(in Commit* child, in Commit* grandParent) pure
					{
						const(Commit)*[] queue = [child];
						const(Commit)*[Hash] seen;

						while (queue.length)
						{
							auto commit = queue[0];
							queue = queue[1..$];
							foreach (parent; commit.parents)
							{
								if (parent.hash in seen)
									continue;
								seen[parent.hash] = commit;

								if (parent is grandParent)
								{
									const(Commit)*[] path;
									while (commit)
									{
										path ~= commit;
										commit = seen.get(commit.hash, null);
									}
									path.reverse();
									return path;
								}

								queue ~= parent;
							}
						}
						throw new Exception("No path between commits");
					}

					bool dbg = false; //c.hash.toString() == "9545447f8529cafab0fb2c51527541870db844b6";
					auto grandParents = memoize!commonParentsOfMerge(c);
					if (dbg) writeln(grandParents.map!(c => c.hash.toString));
					if (grandParents.length == 1)
					{
						bool[] hasMergeCommits = c.parents
							.map!(parent => memoize!commitsBetween(parent, grandParents[0])
								.any!(commit => commit.message[0].startsWith("Merge pull request #"))
							).array;

						if (dbg)
						{
							writefln("%d %s", hasMergeCommits.sum, subject);
							foreach (parent; c.parents)
							{
								writeln("---------------------");
								foreach (cm; memoize!commitsBetween(parent, grandParents[0]))
									writefln("%s %s", cm.hash.toString(), cm.message[0]);
								writeln("---------------------");
							}
						}

						if (hasMergeCommits.sum == 1)
							c = c.parents[hasMergeCommits.indexOf(true)];
						else
							c = c.parents[0];
					}
					else
						c = c.parents[0];
				}
				else
					c = c.parents.length ? c.parents[0] : null;
			} while (c);
			repoMerges[repoName] = merges;
			//writefln("%d linear history commits in %s", linearHistory.length, repoName);
		}

		auto allMerges = repoMerges.values.join;
		allMerges.sort!(`a.commit.time > b.commit.time`, SwapStrategy.stable)();
		allMerges.reverse();
		auto end = allMerges.countUntil!(m => m.commit.time > latestTime);
		if (end >= 0)
			allMerges = allMerges[0..end];

		f.writefln("reset %s", refName);

		Hash[string] state;
		foreach (m; allMerges)
		{
			auto parentMark = marks[state.values.sort().release];
			state[m.repo] = m.commit.hash;

			auto hashes = state.values.sort().release.assumeUnique();
			if (hashes in marks)
				continue;

			currentMark++;
			marks[hashes] = currentMark;

			f.writefln("commit %s", refName);
			f.writefln("mark :%d", currentMark);
			f.writefln("author %s", m.commit.author);
			f.writefln("committer %s", m.commit.committer);

			string[] messageLines = m.commit.message;
			if (messageLines.length)
			{
				// Add a link to the pull request
				auto pullMatch = messageLines[0].match(re!`^Merge pull request #(\d+) from `);
				if (pullMatch)
				{
					size_t p;
					while (p < messageLines.length && messageLines[p].length)
						p++;
					messageLines = messageLines[0..p] ~ ["", "https://github.com/dlang/%s/pull/%s".format(m.repo, pullMatch.captures[1])] ~ messageLines[p..$];
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
			foreach (name; state.keys.sort())
			{
				f.writefln("[submodule \"%s\"]", name);
				f.writefln("\tpath = %s", name);
				f.writefln("\turl = git://github.com/dlang/%s", name);
			}
			f.writeln("DELIMITER");
			f.writeln();
		}

		f.writefln("reset %s", refName);
		f.writefln("from :%d", marks[state.values.sort().release]);

		currentMark++; // force explicit "from" for new refs
	}

	f.close();
	if (pretend)
		return;

	auto status = pipes.pid.wait();
	enforce(status == 0, "git-fast-import failed with status %d".format(status));

	repo.gitRun("reset", "--hard", "master");
	debug
		stderr.writeln("Not pushing in debug build.");
	else
	{
		repo.gitRun("remote", "add", "origin", "ssh://git@bitbucket.org/cybershadow/d.git");
		repo.gitRun("push", "--mirror", "origin");
	}
}
