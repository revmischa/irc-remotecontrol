#!/usr/bin/env perl

use strict;
use warnings;

use lib 'lib';
use IRC::RemoteControl;
use AnyEvent;
use AnyEvent::Socket;

my $cv = AnyEvent->condvar;

# you can pass in defaults here, e.g. target_address => 'irc.freenode.net'
my $rc = IRC::RemoteControl->new_with_options();

$SIG{INT} = sub {
    warn "Shutting down...\n";
    undef $rc;
    $cv->send;
};

$rc->start;

$cv->recv; # main loop

