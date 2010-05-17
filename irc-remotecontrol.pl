#!/usr/bin/env perl

use strict;
use warnings;

use lib 'lib';
use IRC::RemoteControl;
use AnyEvent;
use AnyEvent::Socket;

my $rc = IRC::RemoteControl->new_with_options(require_proxy => 1);
$rc->start;

AnyEvent->condvar->recv; # main loop

