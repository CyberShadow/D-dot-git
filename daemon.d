module daemon;

import std.exception;
import std.file;
import std.format;
import std.path;
import std.process;
import std.stdio;

import ae.sys.log;

const eventFile = "../pending-events/push.json";

void main()
{
	auto log = createLogger("Daemon");

	while (true)
	{
		if (eventFile.exists)
		{
			eventFile.remove();
			log("Running...");
			run();
		}
		else
		{
			log("Idling...");
			spawnProcess(["inotifywait", "-qq", eventFile.dirName()]).wait();
		}
	}
}

void run()
{
	auto output = File("d-dot-git.log", "wb");
	auto p = spawnProcess(["timeout", "300", absolutePath("d-dot-git")], stdin, output, output).wait();
	enforce(p == 0, "d-dot-git exited with status %d".format(p));
}
