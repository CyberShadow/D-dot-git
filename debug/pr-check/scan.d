import std.algorithm.iteration;
import std.conv;
import std.exception;
import std.file;
import std.json;
import std.path;
import std.process;
import std.stdio;
import std.string;

import ae.sys.file;
import ae.utils.regex;

void main()
{
	foreach (branch; ["master", "stable"])
	{
		bool[uint][string] sawPR;
		{
			auto result = execute(["git", "log", "--pretty=format:%s", branch], null, Config.none, size_t.max, "../../result");
			enforce(result.status == 0, "git log failed");

			foreach (line; result.output.splitLines())
			{
				line.matchCaptures(re!`^(\S+): Merge pull request #(\d+) from `,
					(string component, uint pr) { sawPR[component][pr] = true; });
				line.matchCaptures(re!`^(\S+): .* \(#(\d+)\)$`,
					(string component, uint pr) { sawPR[component][pr] = true; });
			}
		}

		foreach (repo; ["dlang.org", "dmd", "druntime", "installer", "phobos", "tools"])
		{
			static void getPRs(string target, string repo)
			{
				auto f = File(target, "wb");
				foreach (pr; format!"~/work/extern/D/pulls/pulls-%s.json"(repo).expandTilde.readText.parseJSON.array)
					if (!pr["merged_at"].isNull)
						f.writefln("%d\t%s", pr["number"].integer, pr["base"]["ref"].str);
			}

			string fn = format!"prs-%s.txt"(repo);
			cached!getPRs(fn, repo);
			foreach (t; fn.slurp!(uint, string)("%d\t%s"))
				if (branch == t[1] && t[0] !in sawPR[repo])
					writefln!"%s PR #%d not on %s"(repo, t[0], branch);
		}
	}
}
