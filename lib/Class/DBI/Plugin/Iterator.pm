package Class::DBI::Plugin::Iterator;
use strict;
use base qw/Class::DBI::Iterator/;
use vars qw/$VERSION $PREFETCH/;
$VERSION = 0.10;

$PREFETCH = 3;

sub PREFETCH {
    my $class = shift;
    if (@_ > 0 and $_[0] > 0) {
        $PREFETCH = $_[0] + 0;
    }
    $PREFETCH;
}


my %driver_cache;

sub _get_iterator_class {
	my $driver  = $_[1]->db_Main()->{Driver}->{Name};

	return $driver_cache{$_[1]}{$driver} if($driver_cache{$_[1]}{$driver});

	my ($self,$class) = @_;
	my $subclass = __PACKAGE__;

	if( $driver eq 'mysql' ){
		$subclass .= '::mysql';
	}
	else{
		$subclass .= '::subquery';
	}

	eval qq{require $subclass};
	if($@){ $subclass = __PACKAGE__; }

	$driver_cache{$_[1]}{$driver} = $subclass;

	return $subclass;
}


sub new {
    my($me, $them, $sth, $args, $unknown) = @_;
    my $class = !$unknown ? $me
                          : $me->_get_iterator_class($them);

    bless {
        _class => $them,
        _sql   => $sth->{Statement},
        _args  => $args,
        _count => undef,
        _place => 0,
        _mapper => [],
        _data   => [],
        _prefetch => $them->iterator_prefetch || $me->PREFETCH,
    }, $class;
}

sub sql {
    shift->{_sql};
}
sub args {
    shift->{_args};
}
sub all {
    my $self = shift;
    my $sth = $self->class->db_Main->prepare($self->sql);
    $self->{_class}->sth_to_objects($sth, $self->{_args}, 1);
}
sub prefetch {
    my $self = shift;
    if (@_ > 0 and $_[0] > 0) {
        $self->{_prefetch} = $_[0];
    }
    $self->{_prefetch};
}

sub count {
    my $self = shift;
    return $self->{_count} if defined $self->{_count};
    return $self->all->count if $self->class->iterator_count_type eq 'use all';

    my $select_from_regexp = qr/(?si)^\s*SELECT\s+.+?\s+FROM\s+/;
    my $group_check_regexp = qr/(?si)\s+GROUP\s+BY\s+(.+?)(\s+HAVING\s+.+?)?(\s+ORDER\s+BY\s+.+?)?$/;
    my $order_check_regexp = qr/(?si)\s+ORDER\s+BY\s+.+$/;

    my $sql = $self->sql;
    if ($sql =~ $group_check_regexp) {
        unless ($2) {
            my $group_by = $1;
            $sql =~ s/$select_from_regexp/SELECT COUNT(DISTINCT $group_by) FROM /;
            $sql =~ s/$group_check_regexp//;
        }
        else {
            $sql = sprintf 'SELECT COUNT(*) FROM ( %s ) AS __GROUP_BY__', $sql;
        }
    }
    else{
        $sql =~ s/$select_from_regexp/SELECT COUNT(*) FROM /;
        $sql =~ s/$order_check_regexp//;
    }

    eval {
        my $sth = $self->class->db_Main->prepare($sql);
        $sth->execute(@{$self->{_args}});
        $self->{_count} = $sth->fetch->[0];
        $sth->finish;
    };
    if ($@) {
        #warn "using \$self->all->count\n";
        $self->class->iterator_count_type('use all');
        $self->{_count} = $self->all->count;
    }

    $self->{_count};
}

sub next {
    my $self = shift;

    my $prefetch = $self->prefetch;
    my $index = $self->{_place}++ % $prefetch;

    unless ($index) {
        my $pos = $self->{_place} - 1;
        my $end = $pos + $prefetch - 1;
        my $itr = $self->slice($pos, $end);
        @{$self->{_data}}[0 .. $prefetch - 1] = $itr->data;
    }

    my $use = $self->{_data}[$index];
    unless ($use) {
        $self->{_count} = $self->{_place} - 1 unless defined $self->{_count};
        $self->reset;
        return;
    }

    my @obj = ($self->class->construct($use));
    foreach my $meth ($self->mapper) {
        @obj = map $_->$meth(), @obj;
    }
    warn "Discarding extra inflated objects" if @obj > 1;
    return $obj[0];
}

sub slice {
    my ($self, $start, $end) = @_;
    $end ||= $start;

    my $count = $end - $start + 1;
    my $sql = $self->sql . sprintf ' LIMIT %d OFFSET %d', $count, $start;
    my $sth = $self->class->db_Main->prepare($sql);
    $self->class->sth_to_objects($sth, $self->{_args}, 1);
}

sub delete_all {
    shift->all->delete_all;
}
sub data {
    shift->all->data;
}

sub statement_check_regexp {
    qr/(?si)\sLIMIT\s+\S+((\s*,\s*|\s+OFFSET\s+)\S+)?\s*$/;
}

sub import {
    my $class = shift;
    my %options = map lc $_, @_;
    my $pkg   = caller(0);
    no strict 'refs';

    $pkg->mk_classdata('plugin_iterator_disable');

    $pkg->mk_classdata('iterator_prefetch');
    $pkg->iterator_prefetch($options{prefetch} + 0)
            if $options{prefetch} and $options{prefetch} > 0;

    $pkg->mk_classdata('iterator_count_type');
    my $iterator_class = __PACKAGE__;
    my $driver_unknown = 1;
    if ($options{driver}) {
        $iterator_class .= __PACKAGE__ . "::" . $options{driver};
        eval qq{require $iterator_class};
        $iterator_class = undef if $@;
        $driver_unknown = 0;
    }

    my $statement_check_regexp = $iterator_class->statement_check_regexp;

    *{"$pkg\::sth_to_objects"} = sub {
        my ($class, $sth, $args, $plugin_disable) = @_;
        $class->_croak("sth_to_objects needs a statement handle") unless $sth;
        unless (UNIVERSAL::isa($sth => "DBI::st")) {
            my $meth = "sql_$sth";
            $sth = $class->$meth();
        }

        return $iterator_class->new($class, $sth, $args, $driver_unknown)
                if not $plugin_disable and
                   not $class->plugin_iterator_disable and
                   defined wantarray and not wantarray and
                   $sth->{Statement} !~ $statement_check_regexp;

        my (%data, @rows);
        eval {
            $sth->execute(@$args) unless $sth->{Active};
            $sth->bind_columns(\(@data{ @{ $sth->{NAME_lc} } }));
            push @rows, {%data} while $sth->fetch;
        };
        return $class->_croak("$class can't $sth->{Statement}: $@", err => $@)
                if $@;
        return $class->_ids_to_objects(\@rows);
    }
}

1;
