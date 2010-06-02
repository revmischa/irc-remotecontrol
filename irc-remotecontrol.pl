#!/usr/bin/env perl

use strict;
use warnings;

use lib 'lib';
use IRC::RemoteControl;
use AnyEvent;
use AnyEvent::Socket;

my $cv = AnyEvent->condvar;

my $rc = IRC::RemoteControl->new_with_options(require_proxy => 1);

$SIG{INT} = sub {
    warn "Shutting down...\n";
    undef $rc;
    $cv->send;
};

$rc->start;

$cv->recv; # main loop

