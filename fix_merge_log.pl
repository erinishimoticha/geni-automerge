#!/usr/bin/perl

use strict;

my %profile_pairs_content;
my %profile_pairs_count;

open(FH, "merge_log.html") || die("ERROR: Could not open merge_log.html\n");
while(<FH>) {
	next if (/^\s*$/);

	# 2010-11-12 17:59:06 :: dwalton76@gmail.com :: PENDING_MERGE :: Merged
	# <a href="http://www.geni.com/people/id/6000000008281493450">6000000008281493450</a> with
	# <a href="http://www.geni.com/people/id/6000000010035060446">6000000010035060446</a>
	(my $time, my $user, my $type, my $url) = split(/ :: /, $_);
	$url =~ /\>(\d+)\<.* with .*\>(\d+)\</;
	my $pair = "$1:$2";
	$profile_pairs_content{$pair} = $_;
	$profile_pairs_count{$pair}++; 
}
close FH;

foreach my $i (keys %profile_pairs_count) {
	if ($profile_pairs_count{$i} == 1) {
		print "$profile_pairs_content{$i}\n";
	}
}

