package Mojolicious::Plugin::TtRenderer::Engine;

use warnings;
use strict;
use v5.10;

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

    my $dir;
    my $app = delete $args{mojo} || delete $args{app};
    if($dir=$args{cache_dir}) {

      if($app && substr($dir,0,1) ne '/') {
        $dir=$app->home->rel_dir('tmp/ctpl');
      }
    }

    # TODO
    #   take and process options :-)

    my @renderer_paths = $app ? map { abs_path($_) } grep { -d $_ } @{ $app->renderer->paths } : ();

    my %config = (
        (   @renderer_paths > 0
            ? (INCLUDE_PATH => join(":", @renderer_paths))
            : ()
        ),
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
    my $provider = $self->tt->{SERVICE}->{CONTEXT}->{LOAD_TEMPLATES}->[0];
    $provider->ctx($c);
    $provider->not_found(1);

    my $ok = $self->tt->process(defined $inline ? \$inline : $t, @params);

    return 0 if !defined $inline && $provider->not_found;

    # Error
    die $self->tt->error unless $ok;

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
    $self->{data_files} = {};
    $self->{main_path} = $self->paths->[0];
    $self->renderer($renderer);
    weaken($self->{renderer});
    return $self;
}

sub renderer      { @_ > 1 ? $_[0]->{renderer}      = $_[1] : $_[0]->{renderer} }
sub ctx           { @_ > 1 ? $_[0]->{ctx}           = $_[1] : $_[0]->{ctx} }
sub not_found     { @_ > 1 ? $_[0]->{not_found}     = $_[1] : $_[0]->{not_found} }

# Invoke the real _template_modified and mark the request as found.
sub _template_modified {
    my ($self, $path) = @_;

    if (my $res = $self->_template_modified_base($path)) {
        $self->not_found(0);
        return $res;
    }
}

sub _template_modified_base {
    my ($self, $path) = @_;

    # If we already know the path defines a data-file, return it.
    return 1 if defined $self->{data_files}->{$path};

    # Handle regular files
    if (-r $path) {
        return $self->SUPER::_template_modified($path);
    }

    # This method will be invoked for every include path, but we only need
    # to check the data section once. Therefore we keep track of the first
    # include path and only check if it matches this one.
    my $main_path = $self->{main_path};
    my $base_path = $path;

    if ($base_path =~ s/\A\Q$main_path\///) {
        # Handle backslashes on Windows
        $base_path =~ s/\\/\//g;

        # Maintain an index of which files defines which templates.
        my $loader = Mojo::Loader->new;
        unless ($self->{index}) {
            my $index = $self->{index} = {};
            for my $class (reverse @{$self->renderer->classes}) {
                $index->{$_} = $class for keys %{$loader->data($class)};
            }
        }

        my $data = $loader->data($self->{index}{$base_path}, $base_path);

        if (defined $data) {
            $self->{data_files}->{$path} = $data;
            return 1;
        }
    }

    undef;
}

sub _template_content {
    my ($self, $path) = @_;

    my $data = $self->{data_files}->{$path};

    unless (defined $data) {
        $data = $self->SUPER::_template_content($path);
    }

    return wantarray ? ($data, '', time) : $data;
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

=item cache_dir

Absolute or relative dir to your app home, to cache processed versions of your
templates. Will default to a temp-dir if not set.

=back

=head1 AUTHOR

Current maintainer: Graham Ollis C<< <plicease@cpan.org> >>

Original author: Ask Bjørn Hansen, C<< <ask at develooper.com> >>

=head1 TODO

   * Better support non-Mojolicious frameworks
   * Better way to pass parameters to the templates? (stash)
   * More sophisticated default search path?

=head1 BUGS

Please report any bugs or feature requests to the project's github issue tracker
L<https://github.com/abh/mojox-renderer-tt/issues?state=open>.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Mojolicious::Plugin::TtRenderer::Engine

You can also look for information at:

=over 4

=item * git repository

L<http://git.develooper.com/?p=MojoX-Renderer-TT.git;a=summary>,
L<git://git.develooper.com/MojoX-Renderer-TT.git>

L<http://github.com/abh/mojox-renderer-tt/>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/MojoX-Renderer-TT>

=item * Search CPAN

L<http://search.cpan.org/dist/MojoX-Renderer-TT/>

=back

=head1 COPYRIGHT & LICENSE

Copyright 2008-2010 Ask Bjørn Hansen, all rights reserved.

Copyright 2012 Graham Ollis.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut
