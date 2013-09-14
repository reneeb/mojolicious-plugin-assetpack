package Mojolicious::Plugin::AssetPack;

=head1 NAME

Mojolicious::Plugin::AssetPack - Pack css, scss and javascript with external tools

=head1 VERSION

0.01

=head1 DESCRIPTION

In production mode:

This plugin will automatically compress scss, less, css and javascript with
the help of external application. The result will be one file with all the
sources combined.

This is done using L</pack_javascripts> and L</pack_stylesheets>.

In development mode:

This plugin will expand the input files to multiple javascript / link tags
which makes debugging easier.

This is done using L</expand_files>.

=head1 SYNOPSIS

In your application:

  use Mojolicious::Lite;
  plugin 'AssetPack';
  app->start;

In your template:

  %= asset '/js/jquery.min.js', '/js/app.js';
  %= asset '/less/reset.less', '/sass/helpers.scss', '/css/app.css';

NOTE! You need to have one line for each type, meaning you cannot combine
javascript and css sources on one line.

See also L</register>.

=head1 APPLICATIONS

=head2 less

LESS extends CSS with dynamic behavior such as variables, mixins, operations
and functions. See L<http://lesscss.org> for more details.

Installation on Ubuntu and Debian:

  $ sudo apt-get install npm
  $ sudo npm install -g less

=head2 sass

Sass makes CSS fun again. Sass is an extension of CSS3, adding nested rules,
variables, mixins, selector inheritance, and more. See L<http://sass-lang.com>
for more information.

Installation on Ubuntu and Debian:

  $ sudo apt-get install rubygems
  $ sudo gem install sass

=head2 yuicompressor

L<http://yui.github.io/yuicompressor> is used to compress javascript and css.

Installation on Ubuntu and Debian:

  $ sudo apt-get install npm
  $ sudo npm -g i yuicompressor

=cut

use Mojo::Base 'Mojolicious::Plugin';
use Mojo::ByteStream 'b';
use Mojo::Util qw( md5_sum slurp );
use Fcntl ();
use File::Spec::Functions qw( catfile );
use File::Which;
use constant DEBUG => $ENV{MOJO_COMPRESS_DEBUG} || 0;

our $VERSION = '0.01';
our %APPLICATIONS; # should consider internal usage, may change without warning

=head1 ATTRIBUTES

=head2 out_dir

Defaults to "packed" in the first search path for static files.

=cut

has out_dir => '';

=head1 METHODS

=head2 pack_javascripts

  $bytestream = $self->pack_javascripts($c, @rel_files);

This method will compress the input files to a file in the L</out_dir>
with the name of the MD5 sum of the C<@files>.

Will also run L</yuicompressor> on the input files to minify them.

The returning bytestream will contain a javascript tag.

=cut

sub pack_javascripts {
  my($self, $c, @files) = @_;
  my $out = $self->_out('.js', @files);

  if($out->{fh}) {
    for my $file ($self->_input_files($c, @files)) {
      if($file =~ /\bmin\b/) {
        print { $out->{fh} } slurp $file;
      }
      else {
        $self->_pack_js($file => $out->{fh});
      }
      print { $out->{fh} } "\n";
    }
  }

  return $c->javascript($self->_abs_to_rel($c, $out->{file}));
}

=head2 pack_stylesheets

  $bytestream = $self->pack_stylesheets($c, @rel_files);

This method will compress the input files to a file in the L</out_dir>
with the name of the MD5 sum of the C<@files>.

Will also run L</less> or L</sass> on the input files to minify them.

The returning bytestream will contain a style tag.

=cut

sub pack_stylesheets {
  my($self, $c, @files) = @_;
  my $out = $self->_out('.css', @files);

  if($out->{fh}) {
    for my $file ($self->_input_files($c, @files)) {
      if($file =~ /\.(scss|less)$/) {
        my $method = "_pack_$1";
        $self->$method($file => $out->{fh});
      }
      else {
        print { $out->{fh} } slurp $file;
      }
    }
  }

  return $c->stylesheet($self->_abs_to_rel($c, $out->{file}));
}

=head2 expand_files

  $bytestream = $self->expand_files($c, @rel_files);

This method will return one tag pr. input file which holds the uncompressed
version of the sources.

Will also run L</less> or L</sass> on the input files to convert them to
css, which the browser understand.

The returning bytestream will contain style or javascript tags.

=cut

sub expand_files {
  my($self, $c, @files) = @_;
  my $type = $files[0] =~ /\.(js|css|scss|less)$/ ? $1 : '';

  # $type eq '' will die anyway, so I'm not testing it here

  if($type eq 'js') {
    return b join '', map { $c->javascript($_) } @files;
  }
  else {
    return b join '', map { $c->stylesheet($self->_compile_css($c, $_)) } @files;
  }
}

=head2 find_external_apps

This method is used to find the L</APPLICATIONS>. It will look for the apps
usin L<File::Which> in this order: lessc, less, sass, yui-compressor,
yuicompressor.

=cut

sub find_external_apps {
  my($self, $app, $config) = @_;

  $APPLICATIONS{less} = $config->{less} || which('lessc') || which('less');
  $APPLICATIONS{scss} = $config->{sass} || which('sass');
  $APPLICATIONS{js} = $config->{yuicompressor} || which('yui-compressor') || which('yuicompressor');

  for(keys %APPLICATIONS) {
    $APPLICATIONS{$_} and next;
    $app->log->warn("Could not find application for $_");
  }
}

=head2 register

  plugin 'AssetPack', {
    enable => $bool,
    reset => $bool,
    out_dir => '/abs/path/to/app/public/dir',
    less => '/path/to/lessc',
    sass => '/path/to/sass',
    js => '/path/to/yuicompressor',
  };

Will register the C<compress> helper. All arguments are optional.

"enable" will default to COMPRESS_ASSETS environment variable or set to true
if L<Mojolicious/mode> is "production".

"reset" can be set to true to always rebuild the javascript one the first
request that hit the server.

=cut

sub register {
  my($self, $app, $config) = @_;
  my $enable = $config->{enable} // $ENV{COMPRESS_ASSETS} // $app->mode eq 'production';

  $self->find_external_apps($app, $config);
  $self->out_dir($config->{out_dir} || $app->home->rel_dir('public/packed'));

  mkdir $self->out_dir; # TODO: Use mkpath instead?

  if($config->{enable} and $config->{reset}) {
    opendir(my $DH, $self->out_dir);
    unlink catfile $self->out_dir, $_ for grep { /^\w/ } readdir $DH;
  }

  if($enable) {
    $app->helper(asset => sub {
      my($c, @files) = @_;
      my $type = $files[0] =~ /\.(js|css|scss|less)$/ ? $1 : '';

      if($type eq 'js') {
        return $self->pack_javascripts($c, @files);
      }
      else {
        return $self->pack_stylesheets($c, @files);
      }
    });
  }
  else {
    $app->log->debug('Mojolicious::Plugin::AssetPack will expand file list');
    $app->helper(asset => sub { $self->expand_files(@_) });
  }
}

sub _abs_to_rel {
  my($self, $c, $out) = @_;

  for my $p (@{ $c->app->static->paths }) {
    return $out if $out =~ s!^$p!!;
  }

  die "$out is not found in static paths";
}

sub _compile_css {
  my($self, $c, $file) = @_;

  if($file =~ /\.(scss|less)$/) {
    eval {
      my $in = $c->app->static->file($file)->path;
      (my $out = $in) =~ s/\.(\w+)$/.css/;
      warn "system $APPLICATIONS{$1} $in $out\n" if DEBUG;
      system $APPLICATIONS{$1} => $in => $out;
      $file =~ s/\.(\w+)$/.css/;
    } or do {
      $c->app->log->warn("Could not convert $file: $@");
    };
  }

  $file;
}

sub _pack_js {
  my($self, $in, $OUT) = @_;

  open my $APP, '-|', $APPLICATIONS{js} => $in or die "$APPLICATIONS{js} $in: $!";
  print $OUT $_ while <$APP>;
}

sub _pack_less {
  my($self, $in, $OUT) = @_;

  open my $APP, '-|', $APPLICATIONS{less} => -x => $in or die "$APPLICATIONS{less} -x $in: $!";
  print $OUT $_ while <$APP>;
}

sub _pack_scss {
  my($self, $in, $OUT) = @_;

  open my $APP, '-|', $APPLICATIONS{scss} => -t => 'compressed' => $in or die "$APPLICATIONS{scss} -t compressed $in: $!";
  print $OUT $_ while <$APP>;
}

sub _input_files {
  my($self, $c) = (shift, shift);
  my $static = $c->app->static;

  map {
    my $file = $static->file($_);
    $file ? $file->path : $_;
  } @_;
}

sub _out {
  my($self, $ext) = (shift, shift);
  my $path = catfile $self->out_dir, md5_sum(join '', @_) .$ext;

  use Fcntl qw(O_CREAT O_EXCL O_WRONLY);
  return {
    file => $path,
    fh => IO::File->new($path, O_CREAT | O_EXCL | O_WRONLY),
  };
}

=head1 AUTHOR

Jan Henning Thorsen - C<jhthorsen@cpan.org>

=cut

1;