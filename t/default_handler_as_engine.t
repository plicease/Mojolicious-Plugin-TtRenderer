use strict;
use warnings;
use 5.016;
use Test::More tests => 10;
use Test::Mojo;
use File::Temp qw( tempdir );

use Mojolicious::Lite;
use Mojolicious::Plugin::TtRenderer::Engine ();

my $tt = Mojolicious::Plugin::TtRenderer::Engine->build(
    mojo => app,
    template_options => {
        UNICODE  => 1,
        ENCODING => 'UTF-8',
        COMPILE_DIR  => tempdir( CLEANUP => 1 ),
    }
);

app->renderer->add_handler(tt => $tt);
app->renderer->default_handler('tt');

get '/' => sub {
    die 'foo';
};

get '/bar' => 'bar';

get '/grimlock' => 'grimlock';

my $t = Test::Mojo->new;

$t->get_ok('/')
    ->status_is(500)
    ->content_like(qr{foo});

$t->get_ok('/bar')
    ->status_is(200)
    ->content_like(qr{bar});

$t->get_ok('/grimlock')
    ->status_is(200)
    ->content_like(qr{King});

my $cleaned_up = 0;
sub Guard::DESTROY { $cleaned_up++ };

subtest cleanup => sub {
    plan tests => 4;

    get '/leak-check' => sub {
        my $c = shift;
        $c->stash(
            free_me => bless({}, 'Guard'),
            template => 'bar',
        );
    };

    $t->get_ok('/leak-check')->status_is(200)->content_like(qr/bar/);
    is $cleaned_up, 1, 'object in stash went out of scope after hit';
};

__DATA__

@@ index.html.tt
anything

@@ bar.html.tt
sometimes, the bar, he eats you...
