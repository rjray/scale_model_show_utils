#!/usr/bin/perl

use 5.010;
use strict;
use warnings;

use Cwd qw(cwd);
use File::Basename qw(basename dirname);
use File::Copy qw(cp);
use File::Path qw(make_path remove_tree);
use File::Spec;
use Getopt::Long qw(GetOptionsFromArray);

use Text::CSV;

our $COMMAND = basename $0;
our $VERSION = '0.2';

my $CAT_RE = qr/(\d+)(\w?)/;

my %VERBS = (
    init    => {
        code => \&do_init,
    },
    copy    => {
        code => \&do_copy,
        opts => [ qw(only=s@ slides=s skip=i) ],
    },
    cleanup => {
        code => \&do_cleanup,
    },
    archive => {
        code => \&do_archive,
        opts => [ qw(command=s file=s) ],
    },
    manual  => {
        code => \&do_manual,
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

manual    Display the full manual page.
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
    my $csv = Text::CSV->new;

    if (open my $fh, '<:encoding(utf8)', $source) {
        @lines = <$fh>;
        close $fh or die "Error closing source-file '$source': $!\n";
        chomp @lines;
    } else {
        die "Error opening categories source '$source' for reading: $!\n";
    }

    for my $line (@lines) {
        next if (! $line);
        next if ($line =~ /^#/);

        if ($csv->parse($line)) {
            push @cats, ($csv->fields)[0];
        }
    }

    return @cats;
}

sub do_copy {
    my $env = shift;
    my @words = @{$env->{words}};
    my ($catdir, $predir, @cats, @only, $slides, @cat_errors, @missing_slides);
    my $skip = $env->{skip} || 0;

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
        my $category_path = File::Spec->catdir($catdir, $cat);
        copy_category(
            $cat, $category_path, $predir, $skip, \@cat_errors
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
    my ($catnum, $catsfx, $name);

    if ($cat =~ $CAT_RE) {
        ($catnum, $catsfx) = ($1, $2);
    } else {
        die "Bad category in img_filename: $cat\n";
    }

    if (defined $seq) {
        $name = sprintf '%04d%s-%d.jpg', $catnum, $catsfx, $seq;
    } else {
        $name = sprintf '%04d%s.jpg', $catnum, $catsfx;
    }

    return $name;
}

sub copy_category {
    my ($cat, $from, $to, $skip, $err_list) = @_;
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
        if ($skip) {
            $skip--;
            next;
        }

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

    my $name1 = img_filename($cat, 0);
    my $file1 = File::Spec->catfile($slidesdir, $name1);
    my $name2 = img_filename($cat);
    my $file2 = File::Spec->catfile($slidesdir, $name2);

    if (-f $file1) {
        my $to_file = File::Spec->catfile($to, $name1);
        if (-f $to_file) {
            unlink $to_file;
        }

        cp $file1, $to_file;
    } elsif (-f $file2) {
        my $to_file = File::Spec->catfile($to, $name2);
        if (-f $to_file) {
            unlink $to_file;
        }

        cp $file2, $to_file;
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

=head1 NAME

contest_tool.pl - Manage photos for a contest awards presentation

=head1 USAGE

    contest_tool.pl <action> <options>

=head1 DESCRIPTION

This tool manages the creation of directories for contest categories and creates
an ordered sequence of photos for the awards presentation.

The tool creates a directory structure from a file listing the categories (one
per line) in CSV (comma-separated values) format. Photo files are put into the
directories manually, with the photos of winners ordered in the sequence you
want them in the presentation (usually in reverse order of place). Then, the
tool can create a presentation by ordering the photos based on category order
and file sequence order.

The tool can also create an archive of the presentation, if desired.

=head1 OPTIONS

The command is invoked with one action-word (the "verb") and zero or more
options following it. The set of allowed verbs are:

=head2 init

Initialize a categories directory using data from a provided CSV file. Each
line of the file is read, with any line that starts with a C<#> character being
ignored as a comment line. Blank lines are also ignored. Within the CSV data,
the first column is expected to be the category number, and all other columns
are ignored (by this tool). Each category will have a directory created for it.

The B<init> verb takes one or two arguments, in specific order:

=over 4

=item I<categories-dir>

Optional. This value specifies the name to give the parent directory of all the
category directories. This value may be a relative path or an absolute path. If
this value is not passed, then the default name of F<Categories> (relative to
the current directory) is used. The directory will be created if it does not
already exist.

=item I<datafile>

Required. This value specifies the CSV data file to read category data from.
The file does not have to have any specific suffix, but it is expected to be in
simple ASCII or UTF-8 format plain text.

=back

If only one argument is given, it is assumed to be the CSV file and the default
will be used for the categories directory.

=head2 copy

This action is the work-horse of the tool. It traverses the set of category
directories and copies files into a presentation area in the proper order. When
done, it will report on any categories that were empty or had fewer than three
results, so that this can be cross-checked with the actual results for
consistency.

The B<copy> verb takes two optional positional arguments, and some options:

=over 4

=item I<categories-dir>

The directory name in which the per-category directories were created. If this
parameter is not passed, it defaults to F<Categories>, as with B<init>.

=item I<presentation-dir>

The name of the directory into which the presentation sequence should be
copied. It will be created if it does not already exist. If this parameter is
not passed, it defaults to F<Presentation> (relative to the current directory).

=item C<--slides> I<directory>

If given, use F<directory> as the source of slides for each category. Slides
are expected to be named either F<catnumber-0.jpg> (the category number,
followed by a hyphen and the numeral 0) or simply F<catnumber.jpg>. If this
option is not given, no slides are searched for.

=item C<--only> I<cat1,cat2,...>

Only process the given categories, rather than traversing all sub-directories
within the categories area. This can be helpful for categories that have to be
re-shot, for example, and copied over without re-processing the entire
presentation.

The value of this option is one or more category numbers, separated by commas.
This option may be specified more than once to provide more categories.

=item C<--skip> I<num>

Skip the first I<num> photo files in a category directory. This can be useful
if you have additional photos (such as the category placard and/or results
sheet, for identification purposes). Note that the skips are always from the
first images.

=back

=head2 archive

Create an archive of the presentation files. The archive is created of the
entire presentation directory, so it will get any slides or ancillary images
that you may have added into there. The archive will be a directory (folder),
using the presentation directory as the top-level.

The B<archive> verb takes one optional positional argument, and some options:

=over 4

=item I<presentation-dir>

The name of the presentation directory that was created/used in the B<copy>
step. If this is not passed, it defaults to F<Presentation> relative to the
current directory.

Note that if the value of this argument has more than one directory element to
it, the resulting archive will still only have a folder-depth of 1.

=item C<--command> I<name>

Specify an alternate location for the archive command to use, or force a
different command than the default. The default behavior is to use the B<zip>
command if it is found on the system, or the B<tar> command otherwise. If no
command is found, an error occurs. If the value of this option is an absolute
path, only it will be checked for existence. (A relative path will be searched
through the user's PATH environment.)

Currently, only the B<zip> and B<tar> commands are supported.

=item C<--file> I<path>

Specify an alternate file name for the archive that gets created. If not
passed, then the presentation directory name will be used, with an appropriate
suffix. If passed, this value should I<not> have the file extension. That will
be added by the tool when creating the file.

=back

The archive file is, by default, created in the current working directory.

=head2 cleanup

Clean up the working area of the directories and photo files. Basically the
same as doing recursive removal of the directories, but is available here as a
short-cut to doing so manually.

The B<cleanup> verb take two optional positional arguments:

=over 4

=item I<categories-dir>

The directory name in which the per-category directories were created. If this
parameter is not passed, it defaults to F<Categories>, as with B<init>.

=item I<presentation-dir>

The name of the directory into which the presentation was created. If not
passed, this defaults to F<Presentation> as with B<copy>.

=back

=head2 manual

This action displays this manual page.

=head1 LICENSE AND COPYRIGHT

Copying and distribution are permitted under the terms of the Apache License
Version 2.0 (L<http://www.apache.org/licenses/>). A copy of this license is
distributed with this project in the file F<LICENSE>.

=head1 AUTHOR

Randy J. Ray C<< <rjray@blackperl.com> >>.
