#!/usr/bin/perl

# This is a wrapper script for running geni-automerge.pl on one page at a time.
# This is a temporary fix until we can find the mem leak(s) that cause the script
# to hold hundreds of megs of memory when you run it for more than a few hours.
#
# The api limit is set to 10.  I did this because I typically run 4 copies of
# the script at once and our overall "api limit" is 40.
#
# The syntax is "./wrapper.pl X Y" where X is your -rb and Y is your -re
#
use strict;
my $rb = "";
my $re = "";
my $mode = "";
my $api = "";

for (my $i = 0; $i <= $#ARGV; $i++) {
	if ($ARGV[$i] eq "-api") {
		$api = $ARGV[++$i];
	} elsif ($ARGV[$i] eq "-pms") {
		$mode = "-pms";
	} elsif ($ARGV[$i] eq "-tcs") {
		$mode = "-tcs";
	} elsif ($ARGV[$i] eq "-rb") {
		$rb = $ARGV[++$i];
	} elsif ($ARGV[$i] eq "-re") {
		$re = $ARGV[++$i];
	}
}

die("ERROR: mode must be either -tcs or -pms, you entered '$mode'\n\n") if ($mode ne "-tcs" && $mode ne "-pms");
die("ERROR: you must specify an api value via '-api X'\n\n") if ($api !~ /^\d+$/);
die("ERROR: you must specify a rb value via '-rb X'\n\n") if ($rb !~ /^\d+$/);
die("ERROR: you must specify a re value via '-re X'\n\n") if ($re !~ /^\d+$/);

for (my $i = $re; $i >= $rb; $i--) {
	if ($mode eq "-tcs") {
		if (-e "script_data/tree_conflicts_$i\.json") {
			$re = $i;
		}
	} elsif ($mode eq "-pms") {
		if (-e "script_data/merges_$i\.json") {
			$re = $i;
		}
	}
}

print "$re -> $rb\n";
for (my $i = $re; $i >= $rb; $i--) {
	print "./geni-automerge.pl $mode -all -mlt -api $api -rb $i -re $i\n";
	system "./geni-automerge.pl $mode -all -mlt -api $api -rb $i -re $i";
}
