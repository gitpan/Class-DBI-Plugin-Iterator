package Class::DBI::Plugin::Iterator::subquery;
use strict;
use base qw/Class::DBI::Plugin::Iterator/;

sub count {
    my $self = shift;
    return $self->{_count} if defined $self->{_count};

    my $sql = sprintf 'SELECT COUNT(*) FROM ( %s ) AS __GROUP_BY__', $self->sql;

    eval {
        my $sth = $self->class->db_Main->prepare($sql);
        $sth->execute(@{$self->{_args}});
        $self->{_count} = $sth->fetch->[0];
        $sth->finish;
    };
    if ($@) {
        my $itr = $self->all;
        $self->{_count} = $itr->count;
    }

    $self->{_count};
}

1;
