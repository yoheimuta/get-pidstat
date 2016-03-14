#!/usr/bin/env perl

=encoding utf8

=head1 SYNOPSIS

    $ perl ./get_pidstat.pl --pid_dir=./pid --res_file=./res/bstat.log

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
        column_total => 9,
        column_num   => 6,
    },
    memory => {
        flag         => '-r',
        column_total => 9,
        column_num   => 7,
    },
};

sub new {
    my ( $class, %opt ) = @_;
    bless \%opt, $class;
}

sub new_with_options {
    my $class = shift;
    GetOptions(
        \my %opt, qw/
          pid_dir|p=s
          res_file|r=s
          /
    );
    my $self = $class->new(%opt);
    return $self;
}

sub run {
    my $self = shift;

    opendir my $pid_dir, $self->{pid_dir}
        or die "failed to opendir: $!";

    my @pid_files;
    foreach(readdir $pid_dir){
        next if /^\.{1,2}$/;
        push @pid_files, $_;
    }
    closedir($pid_dir);

    die "empty pid_dir" unless @pid_files;

    my @loop;
    for my $metric_name (keys %$metric_param) {
        for my $cmd_name (@pid_files) {
            push @loop, {
                metric => $metric_name,
                cmd    => $cmd_name,
            };
        }
    }

    my $pm = Parallel::ForkManager->new(scalar @loop);
    $pm->run_on_finish(sub {
        if (my $ret = $_[5]) {
            my ($cmd_name, $ret_pidstat) = @$ret;
            $self->write_ret($cmd_name, $ret_pidstat);
        } else {
            print "failed to collect metrics\n";
        }
    });

    METHODS:
    for my $names (@loop) {
        my $metric_name = $names->{metric};
        my $cmd_name    = $names->{cmd};

        if (my $pid = $pm->start) {
            print "pid=$pid, metric_name=$metric_name, cmd_name=$cmd_name\n";
            next METHODS;
        }

        open my $pid_file, '<', $self->{pid_dir} . "/$cmd_name"
            or die "failed to open: $!";
        chomp(my $pid = <$pid_file>);
        close $pid_file;

        die "invalid pid" unless $pid =~ /^[0-9]+$/;

        my $ret_pidstat = $self->get_pidstat($pid, $metric_name);
        unless ($ret_pidstat && %$ret_pidstat) {
            die "failed getting pidstat: pid=$pid,
                cmd_name=$cmd_name, metric_name=$metric_name";
        }

        $pm->finish(0, [$cmd_name, $ret_pidstat]);
    }
    $pm->wait_all_children;
}

sub get_pidstat {
    my ($self, $pid, $metric_name) = @_;
    my $command = "sleep 2; cat ./source/$metric_name.txt";
    # my $flag = $metric_param->{$metric_name}->{flag};
    # my $command = "pidstat $flag -p $pid 1 60";
    my $output = `$command`;
    die "failed command: $command" unless $output;

    my @lines = split '\n', $output;
    return $self->_parse_ret(\@lines, $metric_name);
}

sub _parse_ret {
    my ($self, $lines, $metric_name) = @_;

    my $p = $metric_param->{$metric_name};

    my $average;
    for (@$lines) {
        my @num = split " ";
        #print "$_," for @num;
        #print "\n";
        next unless @num == $p->{column_total};
        next unless $num[0] eq 'Average:';

        my $cpu = $num[$p->{column_num}];
        next unless $cpu =~ /^[0-9.]+$/;
        $average = $cpu;
    }
    return unless $average;

    my $ret = {
        $metric_name => $average,
    };
    return $ret;
}

sub write_ret {
    my ($self, $name, $ret) = @_;
    open(my $new_file, '>>', $self->{res_file})
        or die "failed to open: $!";

    for my $metric (keys %$ret) {
        print $new_file join (",", $t->epoch, $name, $metric, $ret->{$metric});
        print $new_file "\n";
    }
    close($new_file);
}

package main;

GetPidStat->new_with_options->run;
