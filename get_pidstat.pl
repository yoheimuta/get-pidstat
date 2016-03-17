#!/usr/bin/env perl

=encoding utf8

=head1 SYNOPSIS

    $ carton exec -- perl ./get_pidstat.pl --pid_dir=./pid --res_file=./res/bstat.log --interval=60 --dry_run=0 --include_child=1

=head1 CAUTION

C<interval> must be longer than 5.

=cut
package GetPidStat;
use strict;
use warnings;
use Time::Piece;
use Getopt::Long qw/:config posix_default no_ignore_case bundling auto_help/;
use Parallel::ForkManager;

my $t = localtime;
my $metric_param = {
    cpu => {
        flag         => '-u',
        column_total => 10,
        column_num   => 7,
    },
    memory => {
        flag         => '-r',
        column_total => 10,
        column_num   => 8,
    },
};
my $sleep_sec = 5;

sub new {
    my ( $class, %opt ) = @_;
    bless \%opt, $class;
}

sub new_with_options {
    my $class = shift;
    my %opt = (pid_dir => './pid', res_file => './res/bstat.log',
        interval => '60', dry_run => '1', include_child => '1');

    GetOptions(
        \%opt, qw/
          pid_dir|p=s
          res_file|r=s
          interval|r=s
          dry_run|r=s
          include_child|r=s
          /
    );
    my $self = $class->new(%opt);
    return $self;
}

sub run {
    my $self = shift;

    # pid ファイルの検索を 5 秒後に行う
    sleep $sleep_sec unless $self->{dry_run};

    opendir my $pid_dir, $self->{pid_dir}
        or die "failed to opendir:$!, name=" . $self->{pid_dir};

    my @pid_files;
    foreach(readdir $pid_dir){
        next if /^\.{1,2}$/;

        my $path = $self->{pid_dir} . "/$_";
        my $ok = open my $pid_file, '<', $path;
        unless ($ok) {
            print "failed to open: err=$!, path=$path\n";
            next;
        }
        chomp(my $pid = <$pid_file>);
        close $pid_file;

        unless ($pid =~ /^[0-9]+$/) {
            print "invalid pid: value=$pid\n";
            next;
        }
        push @pid_files, { $_ => $pid };
    }
    closedir($pid_dir);

    die "not found pids in pid_dir: " . $self->{pid_dir} unless @pid_files;

    $self->include_child_pids(\@pid_files) if $self->{include_child};

    my @loop;
    for my $metric_name (keys %$metric_param) {
        for my $info (@pid_files) {
            while (my ($cmd_name, $pid) = each %$info) {
                push @loop, {
                    metric => $metric_name,
                    cmd    => $cmd_name,
                    pid    => $pid,
                };
            }
        }
    }

    my $ret_pidstats;

    my $pm = Parallel::ForkManager->new(scalar @loop);
    $pm->run_on_finish(sub {
        if (my $ret = $_[5]) {
            my ($cmd_name, $ret_pidstat) = @$ret;
            push @{$ret_pidstats->{$cmd_name}}, $ret_pidstat;
        } else {
            print "failed to collect metrics\n";
        }
    });

    METHODS:
    for my $info (@loop) {
        my $metric_name = $info->{metric};
        my $cmd_name    = $info->{cmd};
        my $pid         = $info->{pid};

        if (my $child_pid = $pm->start) {
            printf "child_pid=%d, metric_name=%s, cmd_name=%s, target_pid=%d\n",
                $child_pid, $metric_name, $cmd_name, $pid;
            next METHODS;
        }

        my $ret_pidstat = $self->get_pidstat($pid, $metric_name);
        unless ($ret_pidstat && %$ret_pidstat) {
            die "failed getting pidstat: pid=$$, target_pid=$pid,
                cmd_name=$cmd_name, metric_name=$metric_name";
        }

        $pm->finish(0, [$cmd_name, $ret_pidstat]);
    }
    $pm->wait_all_children;

    $self->write_ret($ret_pidstats);
}

sub include_child_pids {
    my ($self, $pid_files) = @_;

    my @append_files;
    for my $info (@$pid_files) {
        while (my ($cmd_name, $pid) = each %$info) {
            my $child_pids = $self->_search_child_pids($pid);
            for my $child_pid (@$child_pids) {
                unless ($child_pid =~ /^[0-9]+$/) {
                    print "invalid child_pid: value=$child_pid\n";
                    next;
                }
                push @append_files, { $cmd_name => $child_pid };
            }
        }
    }

    push @$pid_files, @append_files;
}

sub _search_child_pids {
    my ($self, $pid) = @_;
    my $command = do {
        if ($self->{dry_run}) {
            "cat ./source/pstree_$pid.txt";
        } else {
            "pstree -pn $pid |grep -o '([[:digit:]]*)' |grep -o '[[:digit:]]*'";
        }
    };
    my $output = `$command`;
    return [] unless $output;

    chomp(my @child_pids = split '\n', $output);
    return \@child_pids;
}

sub get_pidstat {
    my ($self, $pid, $metric_name) = @_;
    my $command = do {
        if ($self->{dry_run}) {
            "sleep 2; cat ./source/$metric_name.txt";
        } else {
            my $flag = $metric_param->{$metric_name}->{flag};
            my $run_sec = $self->{interval} - $sleep_sec;
            "pidstat $flag -p $pid 1 $run_sec";
        }
    };
    my $output = `$command`;
    die "failed command: $command, pid=$$" unless $output;

    my @lines = split '\n', $output;
    return $self->_parse_ret(\@lines, $metric_name);
}

sub _parse_ret {
    my ($self, $lines, $metric_name) = @_;

    my $p = $metric_param->{$metric_name};

    my @metrics;
    for (@$lines) {
        my @num = split " ";
        #print "$_," for @num;
        #print "\n";
        next unless @num == $p->{column_total};

        my $m = $num[$p->{column_num}];
        next unless $m =~ /^[0-9.]+$/;
        push @metrics, $m;
    }
    return unless @metrics;

    my $average = do {
        my $sum = 0;
        $sum += $_ for @metrics;
        sprintf '%.2f', $sum / (scalar @metrics);
    };

    my $ret = {
        $metric_name => $average,
    };
    return $ret;
}

sub write_ret {
    my ($self, $ret_pidstats) = @_;
    open(my $new_file, '>>', $self->{res_file})
        or die "failed to open:$!, name=" . $self->{res_file};

    my $summary;
    while (my ($cmd_name, $rets) = each %$ret_pidstats) {
        for my $ret (@{$rets}) {
            while (my ($mname, $mvalue) = each %$ret) {
                $summary->{$cmd_name}->{$mname} += $mvalue;
            }
        }
    }

    while (my ($cmd_name, $s) = each %$summary) {
        while (my ($mname, $mvalue) = each %$s) {
            # datetime は目視確認用に追加
            print $new_file join (",", $t->datetime, $t->epoch, $cmd_name, $mname, $mvalue);
            print $new_file "\n";
        }
    }
    close($new_file);
}

package main;

GetPidStat->new_with_options->run;
