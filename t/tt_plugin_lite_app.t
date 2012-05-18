#!/usr/bin/env perl

# Copyright (C) 2008-2010, Sebastian Riedel.

use strict;
use warnings;

use File::Temp;
use Mojo::IOLoop;
use Test::More;

# Use a clean temporary directory
BEGIN { $ENV{MOJO_TMPDIR} ||= File::Temp::tempdir }

# Make sure sockets are working
plan skip_all => 'working sockets required for this test!'
  unless Mojo::IOLoop->new->generate_port;
plan tests => 6;

# Leela: OK, this has gotta stop. I'm going to remind Fry of his humanity the way only a woman can.
# Farnsworth: You're going to do his laundry?

use Mojolicious::Lite;
use Test::Mojo;

# POD renderer plugin
plugin 'tt_renderer';

# Silence
app->log->level('error');

# GET /
get '/'     => 'index';
get '/blow' => sub {
    shift->render(template => 'conditional-exception', do_process => 1);
};


my $t = Test::Mojo->new;

# Simple TT template
$t->get_ok('/')->status_is(200)
  ->content_like(qr/test123456/);
$t->get_ok('/blow')->status_is(500)->content_like(qr/file error - doesnotexist.tt: No such file or directory/);

eval "
  use Devel::Cycle 'find_cycle';
  find_cycle(app, sub {
    ok(0, 'Cycle found');
  });
";

