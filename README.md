# get-pidstat

Run `pidstat -w -s -u -d -r` commands in parallel to monitor each process metrics avg/1min.

Output to stdout, a specified file or [Mackerel](https://mackerel.io).

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
$ echo 1234 > /tmp/pid_dir/target_script
$ echo 1235 > /tmp/pid_dir/target_script2
# In production, this file is made and removed by the batch script itself for instance.
```

Run the script every 1 mininute.

```
# vi /etc/cron.d/get_pidstat
* * * * * user carton exec -- perl /path/to/get_pidstat.pl --dry_run=0 --pid_dir=/tmp/pid_dir --res_dir=/tmp/bstat.log

# or run manually
$ cat run.sh
carton exec -- perl /path/to/get_pidstat.pl \
--dry_run=0 \
--pid_dir=/tmp/pid_dir \
--res_dir=/tmp/bstat.log &
sleep 60
$ while true; do sh run.sh; done
```

Done, you can monitor the result.

```
$ tail -f /tmp/bstat.log
# start(datetime),start(epoch),pidfilename,name,value
2016-04-02T19:49:32,1459594172,target_script,cswch_per_sec,19.87
2016-04-02T19:49:32,1459594172,target_script,stk_ref,25500
2016-04-02T19:49:32,1459594172,target_script,memory_percent,34.63
2016-04-02T19:49:32,1459594172,target_script,memory_rss,10881534000
2016-04-02T19:49:32,1459594172,target_script,stk_size,128500
2016-04-02T19:49:32,1459594172,target_script,nvcswch_per_sec,30.45
2016-04-02T19:49:32,1459594172,target_script,cpu,21.2
2016-04-02T19:49:32,1459594172,target_script,disk_write_per_sec,0
2016-04-02T19:49:32,1459594172,target_script,disk_read_per_sec,0
2016-04-02T19:49:32,1459594172,target_script2,memory_rss,65289204000
2016-04-02T19:49:32,1459594172,target_script2,memory_percent,207.78
2016-04-02T19:49:32,1459594172,target_script2,stk_ref,153000
2016-04-02T19:49:32,1459594172,target_script2,cswch_per_sec,119.22
2016-04-02T19:49:32,1459594172,target_script2,nvcswch_per_sec,182.7
2016-04-02T19:49:32,1459594172,target_script2,cpu,127.2
2016-04-02T19:49:32,1459594172,target_script2,disk_read_per_sec,0
2016-04-02T19:49:32,1459594172,target_script2,disk_write_per_sec,0
2016-04-02T19:49:32,1459594172,target_script2,stk_size,771000
```

### Mackerel

Post the results to service metrics.

```
carton exec -- perl /path/to/get_pidstat.pl \
--dry_run=0 \
--pid_dir=/tmp/pid_dir \
--mackerel_api_key=yourkey \
--mackerel_service_name=yourservice
```
