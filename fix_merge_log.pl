#!/usr/bin/perl

# 2010-11-15 00:00:00 :: ofir591@bezeqint.net :: TREE_CONFLICT :: Merged <a href="http://www.geni.com/people/id/6000000003649723174">6000000003649723174</a> with <a href="http://www.geni.com/people/id/6000000007158974849">6000000007158974849</a>

my $prev_line = "";
sub fix_merge_log() {
	my $filename = "merge_log.html";
	if (!(-e $filename)) {
		print "ERROR: '$filename' does not exist\n";
		return;
	}
	
	system "cp $filename $filename\.backup";
	my %merge_count;
	my %merge_content;
	open(FH, $filename);
	while(<FH>) {
		chomp();
		if (/^ ::/) {
			$_ = $prev_line . $_;
		}

		if (/(Merged.*)/) {
			# print "$1\n";
			$merge_count{$1}++;
			$merge_content{$1} = $_;
		}

		$prev_line = $_;
	}
	
	open(DUPS, "> $filename\_dups.html") || die("ERROR: Could not open '$filename\_dups.html'");
	open(NO_DUPS, "> $filename") || die("ERROR: Could not open '$filename'");
	print DUPS "<pre>\n";
	print NO_DUPS "<pre>\n";
	
	foreach my $i (sort {$merge_count{$b} <=> $merge_count{$a}} (keys %merge_count)) {
		if ($merge_count{$i} <= 5) {
			print NO_DUPS "$merge_content{$i}\n";
		} else {
			print DUPS "$merge_count{$i}: $merge_content{$i}\n";
		}
	}
	
	close DUPS;
	close NO_DUPS;
}

sub fix_private_profiles() {
	my $filename = "private_profiles.txt";
	if (!(-e $filename)) {
		print "ERROR: '$filename' does not exist\n";
		return;
	}

	system "cp $filename $filename\.backup";
	open(FH, $filename);
	while(<FH>) {
		chomp();
		$private_profiles{$_} = 1;
	}
	close FH;

	open(NO_DUPS, "> $filename") || die("ERROR: Could not open '$filename'");
	foreach my $i (sort {$a <=> $b} (keys %private_profiles)) {
		print NO_DUPS "$i\n";
	}
	close NO_DUPS;
}

fix_merge_log();
fix_private_profiles();

