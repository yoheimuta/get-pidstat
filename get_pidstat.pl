#!/usr/bin/env perl

=encoding utf8

=head1 SYNOPSIS

    $ carton exec -- perl ./get_pidstat.pl --pid_dir=./pid --res_file=./res/bstat.log --interval=60 --dry_run=0 --include_child=1 --mackerel_api_key=xxx --mackerel_service_name=xxx

=cut
package GetPidStat;
use 5.010;
use strict;
use warnings;
use Time::Piece;
use Getopt::Long qw/:config posix_default no_ignore_case bundling auto_help/;
use Parallel::ForkManager;
use WebService::Mackerel;

my $t = localtime;
my $metric_param = {
    cpu => {
        column_num   => 6,
    },
    memory_percent => {
        column_num   => 12,
    },
    memory_rss => {
        column_num   => 11,
    },
};

sub new {
    my ( $class, %opt ) = @_;
    bless \%opt, $class;
}

sub new_with_options {
    my $class = shift;
    my %opt = (pid_dir => './pid', include_child => '1',
        interval => '60', dry_run => '1');

    GetOptions(
        \%opt, qw/
          pid_dir|p=s
          res_file|r=s
          interval|r=s
          dry_run|r=s
          include_child|r=s
          mackerel_api_key|r=s
          mackerel_service_name|r=s
          /
    );
    my $self = $class->new(%opt);
    return $self;
}

sub run {
    my $self = shift;

    opendir my $pid_dir, $self->{pid_dir}
        or die "failed to opendir:$!, name=" . $self->{pid_dir};

    my @pid_files;
    foreach(readdir $pid_dir){
        next if /^\.{1,2}$/;

        my $path = $self->{pid_dir} . "/$_";
        my $ok = open my $pid_file, '<', $path;
        unless ($ok) {
            say "failed to open: err=$!, path=$path";
            next;
        }
        chomp(my $pid = <$pid_file>);
        close $pid_file;

        unless ($pid =~ /^[0-9]+$/) {
            say "invalid pid: value=$pid";
            next;
        }
        push @pid_files, { $_ => $pid };
    }
    closedir($pid_dir);

    die "not found pids in pid_dir: " . $self->{pid_dir} unless @pid_files;

    $self->include_child_pids(\@pid_files) if $self->{include_child};

    my @loop;
    for my $info (@pid_files) {
        while (my ($cmd_name, $pid) = each %$info) {
            push @loop, {
                cmd => $cmd_name,
                pid => $pid,
            };
        }
    }

    my $ret_pidstats;

    my $pm = Parallel::ForkManager->new(scalar @loop);
    $pm->run_on_finish(sub {
        if (my $ret = $_[5]) {
            my ($cmd_name, $ret_pidstat) = @$ret;
            push @{$ret_pidstats->{$cmd_name}}, $ret_pidstat;
        } else {
            say "failed to collect metrics";
        }
    });

    METHODS:
    for my $info (@loop) {
        my $cmd_name    = $info->{cmd};
        my $pid         = $info->{pid};

        if (my $child_pid = $pm->start) {
            printf "child_pid=%d, cmd_name=%s, target_pid=%d\n",
                $child_pid, $cmd_name, $pid;
            next METHODS;
        }

        my $ret_pidstat = $self->get_pidstat($pid);
        unless ($ret_pidstat && %$ret_pidstat) {
            die "failed getting pidstat: pid=$$, target_pid=$pid, cmd_name=$cmd_name";
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
                    say "invalid child_pid: value=$child_pid";
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
    return [grep { $_ != $pid } @child_pids];
}

sub get_pidstat {
    my ($self, $pid) = @_;
    my $command = do {
        if ($self->{dry_run}) {
            "sleep 2; cat ./source/metric.txt";
        } else {
            my $run_sec = $self->{interval};
            "pidstat -h -u -r -p $pid 1 $run_sec";
        }
    };
    my $output = `$command`;
    die "failed command: $command, pid=$$" unless $output;

    my @lines = split '\n', $output;
    return $self->_parse_ret(\@lines);
}

sub _parse_ret {
    my ($self, $lines) = @_;

    my $ret;

    while (my ($mname, $param) = each %$metric_param) {
        my @metrics;
        for (@$lines) {
            my @num = split " ";
            #say "$_," for @num;
            my $m = $num[$param->{column_num}];
            next unless $m;
            next unless $m =~ /^[0-9.]+$/;
            push @metrics, $m;
        }
        unless (@metrics) {
            printf "empty metrics: mname=%s, lines=%s\n",
                $mname, join ',', @$lines;
            next;
        }

        my $average = do {
            my $sum = 0;
            $sum += $_ for @metrics;
            sprintf '%.2f', $sum / (scalar @metrics);
        };

        $ret->{$mname} = $average;
    }

    return $ret;
}

sub write_ret {
    my ($self, $ret_pidstats) = @_;

    my $new_file;
    if (my $r = $self->{res_file}) {
        open($new_file, '>>', $r) or die "failed to open:$!, name=$r";
    }

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
            my $msg = join (",", $t->datetime, $t->epoch, $cmd_name, $mname, $mvalue);
            if ($new_file) {
                say $new_file $msg;
            } elsif ($self->{dry_run}) {
                say $msg;
            }

            if ($self->{mackerel_api_key} && $self->{mackerel_service_name}) {
                my $content = $self->_send_mackerel($cmd_name, $mname, $mvalue);
                say "mackerel post: $content" if $self->{dry_run};
            }
        }
    }
    close($new_file) if $new_file;
}

sub _send_mackerel {
    my ($self, $cmd_name, $mname, $mvalue) = @_;
    my $graph_name = "custom.batch_$mname.$cmd_name";

    my $mackerel = WebService::Mackerel->new(
        api_key      => $self->{mackerel_api_key},
        service_name => $self->{mackerel_service_name},
    );
    return $mackerel->post_service_metrics([{
        "name"  => $graph_name,
        "time"  => $t->epoch,
        "value" => $mvalue,
    }]);
}

package main;

GetPidStat->new_with_options->run;
