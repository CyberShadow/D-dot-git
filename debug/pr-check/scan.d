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
			string fn = format!"log-%s.txt"(branch);
			static void getLog(string target, string branch)
			{
				auto pid = spawnProcess(["git", "log", "--pretty=format:%s", branch], stdin, File(target, "wb"), stderr, null, Config.none, "../../result");
				enforce(pid.wait == 0, "git log failed");
			}
			cached!getLog(fn, branch);

			foreach (line; fn.readText.splitLines())
			{
				line.matchCaptures(re!`^(\S+): Merge pull request #(\d+) from `,
					(string component, uint pr) { sawPR[component][pr] = true; });
				line.matchCaptures(re!`^(\S+): .* \(#(\d+)\)$`,
					(string component, uint pr) { sawPR[component][pr] = true; });
			}
		}

		foreach (repo; ["dlang.org", "dmd", "druntime", "installer", "phobos", "tools"])
		{
			foreach (pr; format!"~/work/extern/D/pulls/pulls-%s.json"(repo).expandTilde.readText.parseJSON.array)
				if (pr["base"]["ref"].str == branch && !pr["merged_at"].isNull)
				{
					auto n = pr["number"].integer.to!uint;
					if (n !in sawPR[repo])
						writefln!"%s PR #%d not on %s"(repo, n, branch);
				}
		}
	}
}
