package Mojolicious::Plugin::TtRenderer::Engine;

use warnings;
use strict;

use base 'Mojo::Base';

use Carp ();
use File::Spec ();
use Mojo::ByteStream 'b';
use Template ();
use Cwd qw/abs_path/;
use Scalar::Util 'weaken';

__PACKAGE__->attr('tt');

sub build {
    my $self = shift->SUPER::new(@_);
    weaken($self->{app});
    $self->_init(@_);
    return sub { $self->_render(@_) }
}

sub _init {
    my $self = shift;
    my %args = @_;

    #$Template::Parser::DEBUG = 1;

    my $app = delete $args{mojo} || delete $args{app};

    my $dir = $app && $app->home->rel_dir('tmp/ctpl');

    # TODO
    #   take and process options :-)

    my %config = (
        ($app ? (INCLUDE_PATH => abs_path($app->home->rel_dir('templates'))) : ()),
        COMPILE_EXT => '.ttc',
        COMPILE_DIR => ($dir || abs_path(File::Spec->tmpdir)),
        UNICODE     => 1,
        ENCODING    => 'utf-8',
        CACHE_SIZE  => 128,
        RELATIVE    => 1,
        %{$args{template_options} || {}},
    );

    $config{LOAD_TEMPLATES} =
      [Mojolicious::Plugin::TtRenderer::Provider->new(%config, renderer => $app->renderer)]
      unless $config{LOAD_TEMPLATES};

    $self->tt(Template->new(\%config))
      or Carp::croak "Could not initialize Template object: $Template::ERROR";

    return $self;
}

sub _render {
    my ($self, $renderer, $c, $output, $options) = @_;

    # Inline
    my $inline = $options->{inline};

    # Template
    my $t = $renderer->template_name($options);
    $t = 'inline' if defined $inline;
    return unless $t;


    my $helper = Mojolicious::Plugin::TtRenderer::Helper->new(ctx => $c);

    # Purge previous result
    $$output = '';

    my @params = ({%{$c->stash}, c => $c, h => $helper}, $output, {binmode => ':utf8'});
    $self->tt->{SERVICE}->{CONTEXT}->{LOAD_TEMPLATES}->[0]->ctx($c);

    my $ok = $self->tt->process(defined $inline ? \$inline : $t, @params);

    # Error
    unless ($ok) {

        my $e = Mojo::Exception->new(
            $self->tt->error.'',
            $self->tt->service->process(defined $inline ? \$inline : $t));
        $$output = '';
        $c->app->log->error(qq/Template error in "$t": $e/);
        $c->render_exception($e);
        $self->tt->error('');
        return 0;
    }

    return 1;
}

1;    # End of Mojolicious::Plugin::TtRenderer::Engine

package
  Mojolicious::Plugin::TtRenderer::Helper;

use strict;
use warnings;

use base 'Mojo::Base';

our $AUTOLOAD;

__PACKAGE__->attr('ctx');

sub AUTOLOAD {
    my $self = shift;

    my $method = $AUTOLOAD;

    return if $method =~ /^[A-Z]+?$/;
    return if $method =~ /^_/;
    return if $method =~ /(?:\:*?)DESTROY$/;

    $method = (split '::' => $method)[-1];

    die qq/Unknown helper: $method/ unless $self->ctx->app->renderer->helpers->{$method};

    return $self->ctx->$method(@_);
}

1;

package
  Mojolicious::Plugin::TtRenderer::Provider;

use strict;
use warnings;

use base 'Template::Provider';
use Scalar::Util 'weaken';

sub new {
    my $class = shift;
    my %params = @_;

    my $renderer = delete $params{renderer};

    my $self = $class->SUPER::new(%params);
    $self->renderer($renderer);
    weaken($self->{renderer});
    return $self;
}

sub renderer      { @_ > 1 ? $_[0]->{renderer}      = $_[1] : $_[0]->{renderer} }
sub ctx           { @_ > 1 ? $_[0]->{ctx}           = $_[1] : $_[0]->{ctx} }

sub _template_modified {1}

sub _template_content {
    my $self = shift;
    my ($path) = @_;

    # Convert backslashes to forward slashes to make inline templates work on Windows
    $path =~ s/\\/\//g;
    my ($t) = ($path =~ m{templates\/(.*)$});

    if (-r $path) {
        return $self->SUPER::_template_content(@_);
    }

    # Try DATA section
    elsif (my $d = $self->renderer->get_data_template($self->ctx, $t)) {
        return wantarray ? ($d, '', time) : $d;
    }

    my $data = '';
    my $error = "$path: not found";
    my $mod_date = time;
    return wantarray ? ($data, $error, $mod_date) : $data;
}

1;

__END__

=encoding utf-8

=head1 NAME

Mojolicious::Plugin::TtRenderer::Engine - Template Toolkit renderer for Mojo

=head1 SYNOPSIS

Add the handler:

    sub startup {
        ...

        # Via mojolicious plugin
        $self->plugin(tt_renderer => {template_options => {FILTERS => [ ... ]}});

        # Or manually
        use Mojolicious::Plugin::TtRenderer::Engine;

        my $tt = Mojolicious::Plugin::TtRenderer::Engine->build(
            mojo => $self,
            template_options => {
                PROCESS  => 'tpl/wrapper',
                FILTERS  => [ ... ],
                UNICODE  => 1,
                ENCODING => 'UTF-8',
            }
        );

        $self->renderer->add_handler( tt => $tt );
    }

Template parameter are taken from C< $c->stash >.

=head1 RENDERING

The template file for C<"example/welcome"> would be C<"templates/welcome.html.tt">.

When template file is not available rendering from C<__DATA__> is attempted.

    __DATA__

    @@ welcome.html.tt
    Welcome, [% user.name %]!

Inline template is also supported:

    $self->render(inline => '[% 1 + 1 %]', handler => 'tt');

=head1 HELPERS

Helpers are exported automatically under C<h> namespace.

    [% h.url_for('index') %]

=head1 METHODS

=head2 build

This method returns a handler for the Mojolicious renderer.

Supported parameters are

=over 4

=item mojo
C<build> currently uses a C<mojo> parameter pointing to the base class (Mojo).
object. When used the INCLUDE_PATH will be set to

=item template_options

A hash reference of options that are passed to Template->new().

=back

=head1 AUTHOR

Ask Bjørn Hansen, C<< <ask at develooper.com> >>

=head1 TODO

   * Better support non-Mojolicious frameworks
   * Move the default template cache directory?
   * Better way to pass parameters to the templates? (stash)
   * More sophisticated default search path?

=head1 BUGS

Please report any bugs or feature requests to C<bug-mojox-renderer-tt at rt.cpan.org>,
or through the web interface at
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=MojoX-Renderer-TT>.  I will be
notified, and then you'll automatically be notified of progress on your bug as I
make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Mojolicious::Plugin::TtRenderer::Engine

You can also look for information at:

=over 4

=item * git repository

L<http://git.develooper.com/?p=MojoX-Renderer-TT.git;a=summary>,
L<git://git.develooper.com/MojoX-Renderer-TT.git>

L<http://github.com/abh/mojox-renderer-tt/>

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=MojoX-Renderer-TT>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/MojoX-Renderer-TT>

=item * Search CPAN

L<http://search.cpan.org/dist/MojoX-Renderer-TT/>

=back

=head1 ACKNOWLEDGEMENTS


=head1 COPYRIGHT & LICENSE

Copyright 2008-2010 Ask Bjørn Hansen, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut
