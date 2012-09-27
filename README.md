watchmyback(up)
===============

WMB is a relatively simple set of Ruby scripts designed to do partial incremental backups using rsync.

The idea is that all paths can be sorted into three categories:

 - paths to exclude
 - paths to include
 - paths to watch

The last item is the key difference between WMB and most backup solutions.  By regularly generating a report on what files have changed, it encourages the backup operator to acknowledge that the changing files should either be backed up (included) or ignored (excluded).

Rules
-----

Rules are specified in a simple YAML format.  Each line is a "path: mode" pair, where mode is one of include/exclude/watch.  An example rules.yml is included.

Path rules can be nested arbitrarily deep, so for example, you could define

```yaml
/: exclude
/a: watch
/a/b: include
/a/b/c: watch
/a/b/c/d: include
```

with the result that ```/a``` and ```/a/b/c``` would be watched, but ```/a/b``` and ```/a/b/c/d``` would be included (and not watched).

bin/watch
---------

Usage: ```bin/watch /path/to/rules.yml /path/to/watch-db.json```

Generates a report on changed files since the last time bin/watch was run with the same DB.  This can be run in e.g. a cronjob, or any environment that captures standard output and brings it to the attention of the operator.

Only operates on paths marked "watch" in the rules.  Marking a subdirectory as "include" or "exclude" will prevent watching on that path.

bin/sync
--------

Usage:

 - ```bin/sync /path/to/rules.yml host:/path/to/backup /path/to/rsync.log```
 - ```bin/sync /path/to/rules.yml rsync://host:port/path/to/backup /path/to/rsync.log```
 - rsync log parameter is optional

Performs the backup.  It generates a list of files and directories to send, based on the rules, and then performs an rsync to deliver them to the target.

Only operates on paths marked "include" in the rules.  Marking a subdirectory as "watch" or "exclude" will prevent backing up that path.

bin/cycle
---------

Usage:

 - ```bin/cycle /path/to/backup```
 - ```bin/cycle /path/to/backup format```

_Runs on the backup server, not the client._

Cycles backup directories.  The next time the client runs bin/sync, they will be writing to a new directory.  Any unchanged files will be hardlinked to the previous backup, saving space and transfer time.

The client should be given access to /path/to/backup/upload.  This contains the "current" and "prior" symlinks used for backups and for hardlinks, respectively.  Thus, a client can be granted the ability to perform backups, without having to grant them access to the entire backup history.

An optional timestamp format can be specified.  For example, hourly cycling can be achieved using "%Y-%m-%d.%H".  The default is "%Y-%m-%d", i.e. daily backup cycling.

You can run a backup as many times as you want between cycling.  For example, you can cycle daily, but back up hourly.  This will save space and still maintain fresh backups, but will also mean you can't e.g. see what a file looked like a few hours ago.

Normally, cycling will turn the current directory into the prior directory.  However, if the current directory is empty (no backup was performed since the last cycle), it will delete the current directory and create a new directory and link.  Thus, you can also cycle _more_ often than a machine is performing backups, and also properly handle backup clients that do not operate 24-7.

Putting it all together
-----------------------

Here's an example setup using the above scripts:

 - a backup server ("wmbserver")
  - 24-7 server
  - runs bin/cycle hourly with format "%Y-%m-%d.%H"
  - runs rsync as a daemon (on unprivileged port 8733)
  - has WMB installed at ~/wmb
 - a backup client ("wmbclient")
  - desktop machine, does not run 24-7
  - runs backups hourly
  - generates watch reports every 3 hours by email
  - has WMB installed at ~/wmb
  - has some WMB rules at ~/wmb.yml

The steps to make that happen:

A backup directory on wmbserver: ```mkdir -vp /backups/wmbclient/upload```

A crontab on wmbserver:

```crontab
0 * * * * $HOME/wmb/bin/cycle /backups/wmbclient \%Y-\%m-\%d.\%H
```

An rsyncd.conf on wmbserver:

```ini
[wmbclient]
	path = /backups/wmbclient/upload
	comment = Backups for wmbclient
	read only = false
```

A crontab on wmbclient:

```crontab
MAILTO=your@email.com

33 */3 * * * $HOME/wmb/bin/watch $HOME/wmb.yml /var/tmp/wmb/wmb.json
03 *   * * * $HOME/wmb/bin/sync  $HOME/wmb.yml rsync://wmbserver:8733/wmbclient /var/tmp/wmb/wmb.log
```

And that's it!

Note that I've got the backups on the hour (+3m) and the watches on the half-hour (+3m)  here.  That's just to prevent the two battling for resources at the same time.

The server cycles exactly on the hour, three minutes before the backup, so the timestamp will reflect the current hour.

Don't forget to escape the percent symbols in the cycle format, since "%" is a special character in a crontab.

Caveats
-------

 - File permissions are not preserved.
  - Lack of u+rwx permissions can break rsync.
  - Some environments (e.g. Cygwin) can have some pretty screwed up permissions.
 - Symlinks and special files are not preserved.
  - Needs some thought re: how to avoid confusing the watcher / rsync file lister.
 - Was written in an afternoon.
  - Needs more testing (underway).
  - Needs code cleanup and splitting into multiple files.
