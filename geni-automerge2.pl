#!/usr/bin/perl

use WWW::Geni;
use Log::Log4perl qw(:easy);
use Data::Dumper;
Log::Log4perl->easy_init($DEBUG);

binmode STDOUT, ":utf8";
binmode STDERR, ":utf8";

my $l = get_logger();
my $e;
my $g;

init();


do_tree_conflicts();

sub do_tree_conflicts() {
    my $count, @cur, $compare;
	$count->{'conflict_page'} = 1;
    my $conflictlist = $g->tree_conflicts($count->{'conflict_page'})
		or $l->fatal($WWW::Geni::errstr) && exit(1);
	$l->debug('total is ', $conflictlist->count());
    while (my $conflict = $conflictlist->get_next()){
        $l->debug('processed ', $count->{'conflicts'});
        $count->{'conflicts'}++;
        my $focus = $conflict->profile();
        #$l->debug('# new ', $conflict->type(), ' conflict ############################');
        #$l->debug('Focus:', $focus->first_name, ' ', $focus->middle_name, ' ',
        #    $focus->last_name, ' ', $focus->birth_date, ' ', $focus->death_date, ' ', $focus->guid);
        while (my $memberlist = $conflict->fetch_list()) {
            while (my $member = $memberlist->get_next()) {
                #$l->debug(sprintf("%s: %s %s %s (%s-%s) %s", $memberlist->{type}, $member->first_name,
                #    $member->middle_name, $member->last_name, $member->birth_date, $member->death_date, $member->guid));
                push @cur, $member;
            }
            if (@cur) {
                #$l->debug('Comparing ', $#cur, " ", $memberlist->{type}) if @cur;
                while ($#cur >= 0) {
                    $compare = shift @cur;
                    foreach (@cur) {
                        if (getclass($compare) eq "WWW::Geni::Profile" &&
                            getclass($_) eq "WWW::Geni::Profile" &&
                            compare_profiles($compare, $_)) {
                                #$l->debug("would have merged ", $compare->display_name, " and ", $_->display_name);
                        }
                    }
                }
            }
            undef @cur;
        }
		if (!$conflictlist->has_next()) {
    		$conflictlist = $g->tree_conflicts(++$count->{'conflict_page'})
				or $l->fatal($WWW::Geni::errstr) && exit(1);
		}
    }
}
sub compare_profiles($$) {
    my $p1 = shift;
    my $p2 = shift;
    return 0 if $p1->gender ne $p2->gender;
    return 0 if !compare_first_names($p1->first_name, $p2->first_name);
    return 0 if !compare_middle_names($p1->middle_name, $p2->middle_name);
    return 0 if (
		!compare_surnames($p1->last_name, $p2->last_name)
		&& !compare_surnames($p1->maiden_name, $p2->maiden_name)
		&& !compare_surnames($p1->last_name, $p2->maiden_name)
		&& !compare_surnames($p1->maiden_name, $p2->last_name)
	);
    return 0 if !compare_dates($p1->birth_date, $p2->birth_date);
	#$l->debug("date match: ". $p1->birth_date . " and " . $p2->birth_date);
    return 0 if !compare_dates($p1->death_date, $p2->death_date);
	#$l->debug("date match: ". $p1->death_date . " and " . $p2->death_date);
    return 1;
}

sub compare_dates($$) {
    my $d1 = shift;
    my $d2 = shift;
	return 0 if !$d1 && !$d2;
	return 1 if $d1 eq '' || $d2 eq '';
	return 1 if ($d1 =~ /\b$d2\b/) || ($d2 =~ /\b$d1\b/);
    return 0;
}

sub compare_first_names($$) {
	my $n1 = shift; $n1 = lc($n1);
	my $n2 = shift; $n2 = lc($n2);
	return 0 if is_unknown($n1) || is_unknown($n2);
	return compare_middle_names($n1, $n2);
}

sub compare_middle_names($$) {
	my $n1 = shift; $n1 = lc($n1);
	my $n2 = shift; $n2 = lc($n2);
	return 1 if $n1 eq $n2;
	return 1 if ($n1 =~ /\b$n2\b/) || ($n2 =~ /\b$n1\b/);
	return 0;
}

sub compare_surnames($$) {
	my $n1 = shift; $n1 = lc($n1);
	my $n2 = shift; $n2 = lc($n2);
	$n1 =~ s/,.*//;
	$n2 =~ s/,.*//;
	return compare_middle_names($n1, $n2);
}

sub is_unknown($) {
	my $name = shift;
	return 1 if $name eq '';
	return 1 if $name =~ /\bnn\b/i;
	return 1 if $name =~ /\bn(\. )*n\b/i;
	return 1 if $name =~ /\bunknown\b/i;
	# unknown or no, then first middle last or surname, name
	return 1 if $name =~ /\b(un)(fmls)n\b/i;
}

sub init() {
    unshift @ARGV, 'fake';
    for (my $i = 1; $i <= $#ARGV; $i++) {
        if ($ARGV[$i] =~ /^--/) {
            $ARGV[$i] =~ s/^--//;
            $ARGV[$i] =~ /([^=]+)=*([^=]*)/;
            $e->{$1} = $2 || 1;
        } elsif ($ARGV[$i] =~  /^-/) {
            $ARGV[$i] =~ s/^-//;
            foreach (split(//, $ARGV[$i])) {
                $e->{$_} = 1;
            }
        } else {
            if ($ARGV[$i-1] =~ /^.{1,1}$/ && $e->{$ARGV[$i-1]} == 1) {
                $e->{$ARGV[$i-1]} = $ARGV[$i];
            }
        }
    }
    my $c = 0;
    use Term::InKey;
    do {
        # only ask if we have no data or the last login failed
        if ($c or $e->{'u'} eq '' or $e->{'p'} eq '') {
            print "Login failed. Please try again.\n" if $c;
            print "What is your Geni.com email address? ";
            $e->{'u'} = <STDIN>;
            print "What is your Geni.com password? ";
            $e->{'p'} = &ReadPassword;
        }
        $c++;
    } while (!($g = new WWW::Geni({
        'user' => $e->{'u'},
        'pass' => $e->{'p'},
		'client_id' => 'CNctlukY0zCX8sD6ChA4Snrf2BubwL6CGctgkx4U'
    })));
}

sub getclass() {
    my $ref = shift;
    $ref =~ /^([^=]+)=/i;
    return $1;
}

sub help() {

}

