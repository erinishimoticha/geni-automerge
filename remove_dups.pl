#!/usr/bin/perl

# 2010-11-15 00:00:00 :: ofir591@bezeqint.net :: TREE_CONFLICT :: Merged <a href="http://www.geni.com/people/id/6000000003649723174">6000000003649723174</a> with <a href="http://www.geni.com/people/id/6000000007158974849">6000000007158974849</a>

my %merge_count;
my %merge_content;
while(<STDIN>) {
	chomp();
	if (/(Merged.*)/) {
		# print "$1\n";
		$merge_count{$1}++;
		$merge_content{$1} = $_;
	}
}

foreach my $i (keys %merge_count) {
	if ($merge_count{$i} < 10) {
		print "$merge_content{$i}\n";
	}
}
