
#!/usr/bin/perl

use v5.18;
use warnings;

# this needs to be my fork of PPI
# see https://github.com/adamkennedy/PPI/pull/186
use PPI;

use PPI::Xref;
use Git::Repository;
use JSON::XS qw(encode_json);
use Digest::SHA1 qw(sha1_hex);
use File::Basename qw(basename);
use MIME::Base64 qw(encode_base64);

my($path_to_repo, $file_in_repo) = @ARGV;
my $reponame = basename($path_to_repo);

my $xref = PPI::Xref->new({
    INC => ["$path_to_repo/lib", @INC],
});
$xref->process($file_in_repo);

my %_cache;

my $sfi = $xref->subs_files_iter;
while(my $sf = $sfi->next) {
    my($fqsubname, $source_file) = $sf->array;

    my @components = split(/::/, $fqsubname);
    my $relsubname = pop(@components);
    my $pkg = join("::", @components);

    my $vname_of_package = package_($pkg);

    # TODO make sure PPI::Xref and PPI share a cache
    my $doc = $_cache{$source_file} //= PPI::Document->new(
        $source_file,
        readonly => 1,
    ) or next;

    my $subs = $doc->find("PPI::Statement::Sub") or next;
    for my $sub (@$subs) {
        my $child = $sub->schild(1);
        # this is wrong in multiple ways but oh well
        if(
            not $child->isa("PPI::Token::Word")
            or (
                $sub->name ne $fqsubname
                and $sub->name ne $relsubname
            )
        )
        {
            next;
        }

        my $span = $child->byte_span or next;

        my $vname_of_source = file($source_file);
        my $vname_of_sub    = sub_($vname_of_source, $fqsubname, $relsubname);
        my $vname_of_anchor = anchor($vname_of_source, $span);

        edge($vname_of_sub, "childof", $vname_of_package);
        edge($vname_of_sub, "defines", $vname_of_sub); # XXX defines/binding?
    }
}

my $ifi = $xref->incs_files_iter;
while(my $if = $ifi->next) {
    my(
        $source_file,
        $linenumber,
        $target_file,
        $inlcude_type,
        $include_target,
    ) = $if->array;

    my $vname_of_source = file($source_file);
    my $vname_of_target = file($target_file);

    #vcs($source_file);
    #vcs($target_file);

    # need to re-parse to get access to tokens
    # XXX expose PPI documents from PPI::Xref?

    # TODO make sure PPI::Xref and PPI share a cache
    my $doc = $_cache{$source_file} //= PPI::Document->new(
        $source_file,
        readonly => 1,
    ) or next;
    my $incs = $doc->find("PPI::Statement::Include") or next;
    for my $inc (@$incs) {
        my $child = $inc->schild(1) or next;

        if(
            not $child->isa("PPI::Token::Word")
            or $child->content ne $include_target
        )
        {
            next;
        }

        my $span  = $child->byte_span or next;
        my $vname_of_anchor = anchor($vname_of_source, $span);

        # ref/includes is defined as "inlined text" but whatevs
        edge($vname_of_anchor, "ref/includes", $vname_of_target);
        #edge($vname_of_anchor, "ref", $vname_of_target);
    }
}

# TODO synthesise 'main' package for scripts

my $pfi = $xref->packages_files_iter;
while(my $pf = $pfi->next) {
    my(
        $pkg,
        $source_file,
    ) = $pf->array;

    my $doc = $_cache{$source_file} //= PPI::Document->new(
        $source_file,
        readonly => 1,
    ) or next;

    my $vname_of_source = file($source_file);

    my $pkgs = $doc->find("PPI::Statement::Package") or next;
    for my $pkg_stmt (@$pkgs) {
        my $vname_of_package = package_($pkg);
        edge($vname_of_package, "childof", $vname_of_source);

        my $child = $pkg_stmt->schild(1);
        if(
            not $child->isa("PPI::Token::Word")
            or $pkg ne $pkg_stmt->namespace
        )
        {
            next;
        }

        # FIXME the spec says that class definitions span their entire body
        my $span  = $child->byte_span or next;
        my $vname_of_anchor = anchor($vname_of_source, $span);
        edge($vname_of_anchor, "ref", $vname_of_package);
        # not sure this is picked up by web ui
        edge($vname_of_anchor, "defines", $vname_of_package);
    }
}

sub anchor {
    my($vname_of_file, $span) = @_;

    my($start, $end) = @$span;
    $end++;

    my $vname_of_anchor = {
        corpus    => $vname_of_file->{corpus},
        path      => $vname_of_file->{path},
        language  => "perl5",
        signature => "$vname_of_file->{path}#$start,$end",
        root      => $vname_of_file->{root},
    };

    # these are the basic minimum to produce a decoration
    fact($vname_of_anchor, "node/kind", "anchor");
    fact($vname_of_anchor, "loc/start", $start);
    fact($vname_of_anchor, "loc/end", $end);

    # this is optional, I think
    edge($vname_of_anchor, "childof", $vname_of_file);

    $vname_of_anchor;
}

sub package_ {
    my($pkg) = @_;

    my $vname_of_package = {
        corpus    => $reponame,
        language  => "perl5",
        signature => sha1_hex($pkg),
    };
    my $vname_of_name = {
        corpus    => $reponame,
        language  => "perl5",
        signature => "package#$pkg",
    };

    fact($vname_of_package, "node/kind", "package");
    fact($vname_of_name, "node/kind", "name");
    edge($vname_of_package, "named", $vname_of_name);

    $vname_of_package;
}

sub file {
    my($file) = @_;

    my $vname_of_file = {
        corpus    => $reponame,
        path      => $file =~ s/$path_to_repo//r,
        language  => "perl5",
    };
    my $vname_of_name = {
        corpus    => $reponame,
        language  => "perl5",
        signature => "file#$file",
    };

    fact($vname_of_file, "node/kind", "file");
    fact($vname_of_file, "text", slurp($file));
    edge($vname_of_file, "named", $vname_of_name);

    $vname_of_file;
}

# TODO import entire history?
sub vcs {
    my($vname_of_file) = @_;

    state $git = Git::Repository(git_dir => $path_to_repo);
    state $rev = $git->run("rev-parse", "HEAD");

    my $vname_of_vcs = {
        corpus    => $vname_of_file->{corpus},
        signature => "revision#$rev",
        language  => "perl5",
    };

    # XXX need a file -> revision edge?

    fact($vname_of_vcs, "node/kind", "vcs");
    fact($vname_of_vcs, "vcs/id", $rev);
    fact($vname_of_vcs, "vcs/type", "git");
    fact($vname_of_vcs, "vcs/uri", "git:/path/$vname_of_file->{corpus}"); # FIXME

    $vname_of_vcs;
}

sub sub_ {
    my($vname_of_file, $fqname, $relname) = @_;

    my $vname = {
        corpus    => $reponame,
        #path      => , # ???
        signature => "function#".sha1_hex($vname_of_file->{path}.$fqname),
        language  => "perl5",
    };

    fact($vname, "node/kind", "function");
    fact($vname, "complete", "complete");

    if($relname eq "new") {
        fact($vname, "subkind", "constructor");
    }
    elsif($relname eq "DESTROY") {
        fact($vname, "subkind", "destructor");
    }

    $vname;
}

sub edge {
    my($from, $what, $to) = @_;

    say encode_json({
        source => $from,
        target => $to,
        edge_kind  => "/kythe/edge/$what",
        fact_name  => "/",
        fact_value => "",
    });
}

sub fact {
    my($vname, $name, $value) = @_;

    say encode_json({
        source     => $vname,
        fact_name  => "/kythe/$name",
        fact_value => encode_base64($value, ""),
    });
}

sub slurp {
    my($file) = @_;
    open(my $fh, "<", $file) or warn("$file: $!") and return "";
    local $/;
    <$fh>;
}
