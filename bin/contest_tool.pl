#!/usr/bin/perl

use strict;
use warnings;

use Cwd qw(cwd);
use File::Basename qw(basename dirname);
use File::Copy qw(cp);
use File::Path qw(make_path remove_tree);
use File::Spec;
use Getopt::Long qw(GetOptionsFromArray);

our $COMMAND = basename $0;
our $VERSION = '0.2';

my $CAT_RE = qr/(\d+)(\w?)/;

my %VERBS = (
    init    => {
        code => \&do_init,
    },
    copy    => {
        code => \&do_copy,
        opts => [ qw(only=s@ slides=s) ],
    },
    cleanup => {
        code => \&do_cleanup,
    },
    archive => {
        code => \&do_archive,
        opts => [ qw(command=s file=s) ],
    },
);

my $environment = process_args(@ARGV);
$environment->{code}->($environment);

exit;

sub process_args {
    my @args = @_;
    my %env  = ();
    my ($verb, $opts);

    my $USAGE = <<"USAGE";
USAGE: $COMMAND <verb> [ args ... ]

Where <verb> is one of:

init      Initialize the category structure.

          'init' must be followed by the name of the file containing the
          category information. This file should consist of lines of comma-
          separated data, with the category number being the first element of
          each line. Blank lines and lines that start with non-numbers are
          ignored.

          An optional second argument is treated as the name of the categories
          directory to create. If not passed, it defaults to "Categories" (in
          the current directory).

copy      Copy files from categories to the presentation area.

          'copy' should be followed by the names of the categories top-level
          directory, and the name of the directory for the presentation. If
          only one element is present, it is assumed to be the presentation
          name and the default categories location of "Categories" is assumed.
          If no elements are given, "Categories" and "Presentation" are used.

          'copy' takes the following optional arguments:

          --only <list>    <list> is a comma-separated list of one or more
                           category numbers. Only those specified will be
                           copied. Any others will be silently skipped. This
                           option may be provided more than once, and all
                           values will be gathered together.

          --slides <dir>   <dir> is a directory name in which the slides for
                           each category can be found. If not given, no slides
                           will be looked for. If given, any category that
                           gets processed but has no slide will be reported.

cleanup   Clean up presentation and/or categories.

          'cleanup' should be followed by one or two directory names,
          signalling what to clean up. If none are passed, then "Categories"
          and "Presentation" are assumed. If only one is passed, then only
          that directory is cleaned; the onther is not assumed.

archive   Archive the presentation.

          'archive' creates an archive of the presentation. It should be
          followed by name of the presentation directory, defaulting to
          "Presentation" if none is given.

          'archive' takes the following arguments:

          --command <path>  The archive command to use. Defaults to 'zip' if
                            found on the system, or 'tar' otherwise. If none
                            are found, an error will be thrown. May be a full
                            path. Must resolve to one of 'tar' or 'zip'.

          --file <path>     Name of the archive file to create. If not given,
                            then the name of the presentation directory is
                            used. Note that the file will be automatically
                            given a suffix based on the archive command used,
                            so do not include the suffix in this name.

USAGE

    if ($args[0] && $args[0] =~ /^-{1,2}h(?:elp)?$/) {
        # Show the usage without an error exit code.
        print $USAGE;
        exit 0;
    } elsif ((! @args) or (! $VERBS{$args[0]})) {
        # No verb or unrecognized verb.
        die "No verb or unrecognized verb.\n\n$USAGE\n";
    } else {
        $verb = shift @args;
        $opts = $VERBS{$verb};
    }

    $env{code} = $opts->{code};
    if (my $optspec = $opts->{opts}) {
        GetOptionsFromArray(\@args, \%env, @{$optspec}) or
            die "$USAGE\n";
    }

    $env{words} = [ @args ];

    return \%env;
}

sub do_init {
    my $env = shift;
    my @words = @{$env->{words}};

    if (! @words) {
        die "'init' requires at least a file of categories.\n";
    }

    my @categories = read_cats_source($words[0]);
    my $catdir = $words[1] || 'Categories';

    if (! -d $catdir) {
        print "Creating directory '$catdir'.\n";
        make_path $catdir;
    }

    for my $cat (@categories) {
        print "Creating directory '$catdir/$cat'.\n";
        my $path = File::Spec->catdir($catdir, $cat);
        make_path $path;
    }

    return;
}

sub read_cats_source {
    my $source = shift;
    my (@lines, @cats);

    if (open my $fh, '<', $source) {
        @lines = <$fh>;
        close $fh or die "Error closing source-file '$source': $!\n";
        chomp @lines;
    } else {
        die "Error opening categories source '$source' for reading: $!\n";
    }

    for my $line (@lines) {
        next if ($line !~ /^\d/);

        push @cats, (split /,/ => $line)[0];
    }

    return @cats;
}

sub do_copy {
    my $env = shift;
    my @words = @{$env->{words}};
    my ($catdir, $predir, @cats, @only, $slides, @cat_errors, @missing_slides);

    if (@words > 1) {
        ($catdir, $predir) = @words;
    } elsif (@words == 1) {
        $catdir = 'Categories';
        $predir = $words[0];
    } else {
        $catdir = 'Categories';
        $predir = 'Presentation';
    }

    if ($env->{only}) {
        @only = split /,/ => join q{,}, @{$env->{only}};
    }

    if ($slides = $env->{slides}) {
        if (! -d $slides) {
            warn "Specified slides directory ($slides) not present. " .
                "Ignoring...\n";
            $slides = q{};
        }
    }

    if (! -d $catdir) {
        die "No categories '$catdir' found; did you run 'init'?\n";
    }

    if (! -d $predir) {
        print "Creating directory '$predir'.\n";
        make_path $predir;
    }

    if (opendir my $dh, $catdir) {
        @cats = grep { /^\d/ } readdir $dh;
        closedir $dh;
    } else {
        die "Error opening dir $catdir for reading: $!\n";
    }

    for my $cat (filter_cats(\@cats, \@only)) {
        copy_category(
            $cat, File::Spec->catdir($catdir, $cat), $predir, \@cat_errors
        );

        $slides && copy_slide($cat, $slides, $predir, \@missing_slides);
    }

    return;
}

sub as_categories {
    my ($anum, $asfx) = $a =~ $CAT_RE;
    my ($bnum, $bsfx) = $b =~ $CAT_RE;

    return ($anum <=> $bnum) || ($asfx cmp $bsfx);
}

sub filter_cats {
    my ($cats, $only) = @_;
    my (@all_cats, @filtered_cats);

    if (@{$only}) {
        my %should_use = map { $_ => 1 } @{$only};
        @filtered_cats = grep { $should_use{$_} } @{$cats};
    } else {
        @filtered_cats = @{$cats};
    }

    @all_cats = sort as_categories @filtered_cats;

    return @all_cats;
}

sub img_filename {
    my ($cat, $seq) = @_;
    my ($catnum, $catsfx);

    if ($cat =~ $CAT_RE) {
        ($catnum, $catsfx) = ($1, $2);
    } else {
        die "Bad category in img_filename: $cat\n";
    }

    return sprintf '%04d%s-%d.jpg', $catnum, $catsfx, $seq;
}

sub copy_category {
    my ($cat, $from, $to, $err_list) = @_;
    my @files;
    my $counter = 0;

    if (opendir my $dh, $from) {
        @files = sort grep { /[.]jpg$/i } readdir $dh;
        closedir $dh;
    } else {
        die "Error opening dir $from for reading: $!\n";
    }

    print "Processing category $cat:\n";
    for my $file (@files) {
        $counter++;
        my $newfile = img_filename($cat, $counter);
        print "\tFile $file -> $newfile\n";

        my $from_path = File::Spec->catfile($from, $file);
        my $to_path   = File::Spec->catfile($to, $newfile);

        if (-f $to_path) {
            unlink $to_path;
        }

        cp $from_path, $to_path;
    }

    if ($counter) {
        printf "\t%d %s copied.\n",
            $counter, ($counter == 1) ? 'entry' : 'entries';
    } else {
        print "\tNo entries found for this category.\n";
    }

    if ($counter < 3) {
        # Short category, unless it's a special-award category
        my ($catnum) = $cat =~ $CAT_RE;
        if ($catnum < 900) {
            push @{$err_list}, [ $cat, $counter ];
        }
    }

    return;
}

sub copy_slide {
    my ($cat, $slidesdir, $to, $missing_list) = @_;

    my $slidename = img_filename($cat, 0);
    my $slidefile = File::Spec->catfile($slidesdir, $slidename);

    if (-f $slidefile) {
        my $to_file = File::Spec->catfile($to, $slidename);
        if (-f $to_file) {
            unlink $to_file;
        }

        cp $slidefile, $to_file;
    } else {
        warn "No slide file found for category $cat.\n";
        push @{$missing_list}, $cat;
    }

    return;
}

sub do_cleanup {
    my $env = shift;
    my @dirs = @{$env->{words}};
    if (! @dirs) {
        @dirs = qw(Categories Presentation);
    }

    for my $dir (@dirs) {
        print "Removing directory $dir.\n";
        remove_tree $dir;
    }

    return;
}

sub do_archive {
    my $env = shift;
    my ($target, $file, $tool, $type);
    my %args = (
        zip => [ qw(-r -9) ],
        tar => [ qw(-cvzf)],
    );
    my %suffix = (
        zip => 'zip',
        tar => 'tgz',
    );

    $target = $env->{words}->[0] || 'Presentation';
    if ($env->{file}) {
        $file = $env->{file};
    } else {
        $file = $target;
    }
    $tool = find_tool($env->{command});
    $type = basename $tool;
    $type =~ s/[.]exe//; # Future Win support

    if ($args{$type}) {
        $file .= ".$suffix{$type}";

        my $chdir_needed = 0;
        my $cwd = cwd;
        my $basedir = dirname $target;
        if ($basedir ne q{.}) {
            $chdir_needed++;
            chdir $basedir or die "Failed to chdir to $basedir: $!\n";
        }

        system $tool, @{$args{$type}}, $file, $target;
        if ($?) {
            if ($? == -1) {
                die "$tool failed to execute: $!\n";
            } elsif ($? & 127) {
                my $msg = sprintf 'child died with signal %d, %s coredump',
                    ($? & 127), ($? & 128) ? 'with' : 'without';
                die "$tool failed: $msg\n";
            } else {
                my $msg = sprintf 'child exited with value %d', $? >> 8;
                die "$tool failed: $msg\n";
            }
        }

        if ($chdir_needed) {
            chdir $cwd or die "Failed to chdir back to $cwd: $!\n";
        }
    } else {
        die "Unknown archive tool '$tool'. Must be either tar or zip.\n";
    }

    return;
}

sub find_tool {
    my $provided = shift;
    my $tool;

    if ($provided) {
        if (File::Spec->file_name_is_absolute($provided)) {
            if (-f $provided) {
                $tool = $provided;
            } else {
                die "Specified archive tool '$provided' not found.\n";
            }
        } else {
            $tool = find_in_path($provided);
            if (! $tool) {
                die "Unable to find specified archive tool '$provided'.\n";
            }
        }
    } else {
        if (! ($tool = find_in_path('zip'))) {
            if (! ($tool = find_in_path('tar'))) {
                die "Unable to find either 'zip' or 'tar' in path.\n";
            }
        }
    }

    return $tool;
}

sub find_in_path {
    my $cmd = shift;
    my @path = File::Spec->path;

    my @matches = grep { -f } (map { File::Spec->catfile($_, $cmd) } @path);

    return $matches[0];
}

sub do_manual {
    require Pod::Text::Overstrike;

    # First identify the pager to use:
    my $pager;
    if (! ($pager = $ENV{PAGER})) {
        # No env var set. Try to find "less":
        if (! ($pager = find_in_path('less'))) {
            # OK, no "less". Look for "more":
            if (! ($pager = find_in_path('more'))) {
                # Huh?
                $pager = '/bin/cat';
            }
        }
    }

    my $formatter = Pod::Text::Overstrike->new;
    open my $to_pager, q{|-}, $pager or die "Unabled to fork: $!\n";
    $formatter->parse_from_file($0, $to_pager);
    close $to_pager or die "Error on $pager: $!\n";

    return;
}

__END__
