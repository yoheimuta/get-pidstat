# get-pidstat

Run `pidstat` commands in parallel to monitor each process CPU% and Memory% avg/1min.

## Motivation

A batch server runs many batch scripts at the same time.

When this server suffers by a resource short, it's difficult to grasp which processes are heavy quickly.

Running `pidstat` manually is not appropriate in this situation, because

- the target processes are changed by starting each job.
- the target processes may run child processes recursively.

## Installation

To install, please use carton.

```
$ carton install
...
```

## Requirements

`pidstat`
`pstree`
`grep`

## Usage

Prepare pid files in a specified directory.

```
$ mkdir /tmp/pid_dir
$ echo 1234 > /tmp/pid_dir/cpu_heavy_batch
$ echo 1235 > /tmp/pid_dir/mem_heavy_batch
# In production, this file is made and removed by the batch script itself for instance.
```

Run the script every 1 mininute.

```
# vi /etc/cron.d/get_pidstat
* * * * * user carton exec -- perl /path/to/get_pidstat.pl --dry_run=0 --pid_dir=/tmp/pid_dir --res_dir=/tmp/bstat.log

# or run manually
$ cat run.sh
plenv exec carton exec -- perl /path/to/get_pidstat.pl --dry_run=0 --pid_dir=/tmp/pid_dir --res_dir=/tmp/bstat.log &
sleep 60
$ while true; do sh run.sh; done
```

Done, you can monitor the result, send one to a monitoring tool.

```
$ tail -f /tmp/bstat.log
# start(datetime),start(epoch),pidfilename,type(cpu or memory),value(cpu% or memory%)
2016-03-19T11:16:00,1458353760,cpu_heavy_batch,cpu,40.39
2016-03-19T11:16:00,1458353760,cpu_heavy_batch,memory,13.1
2016-03-19T11:16:00,1458353760,mem_heavy_batch,cpu,0.02
2016-03-19T11:16:00,1458353760,mem_heavy_batch,memory,33.63
2016-03-19T11:17:00,1458353820,cpu_heavy_batch,cpu,50.39
2016-03-19T11:17:00,1458353820,cpu_heavy_batch,memory,13.19
2016-03-19T11:17:00,1458353820,mem_heavy_batch,cpu,1.05
2016-03-19T11:17:00,1458353820,mem_heavy_batch,memory,20.59
```

## TODO

Support `pidstat -h` to refactor misc.
