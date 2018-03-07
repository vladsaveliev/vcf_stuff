#!/usr/bin/env python
import tempfile
from os.path import dirname, abspath, join, basename, isfile
import click
import os
import yaml
from ngs_utils.file_utils import splitext_plus
from ngs_utils.logger import err, critical
import pandas as pd
from python_utils.hpc import find_loc, get_ref_file, get_genomes_d
import locale

try:
    if 'UTF-8' not in locale.getlocale(locale.LC_ALL):
        locale.setlocale(locale.LC_ALL, 'en_AU.UTF-8')
except TypeError:
    pass


def package_path():
    return dirname(abspath(__file__))


@click.command()
@click.argument('truth')
@click.argument('vcfs', nargs=-1, type=click.Path(exists=True))
@click.option('-g', 'genome', default='GRCh37')
@click.option('-o', 'output_dir', type=click.Path())
@click.option('-r', 'regions', type=click.Path())
@click.option('-j', 'jobs', type=click.INT, default=1)
@click.option('--anno-tricky', 'anno_tricky', is_flag=True)
def main(truth, vcfs, genome, output_dir=None, regions=None, jobs=1, anno_tricky=False):
    if not vcfs:
        raise click.BadParameter('Provide at least one VCF file')

    config = {
        'samples': {splitext_plus(basename(v))[0]: abspath(v) for v in vcfs
                    if v.endswith('.vcf') or v.endswith('.vcf.gz')},
        'anno_tricky': anno_tricky,
    }
    if regions:
        config['sample_regions'] = regions

    loc = find_loc()

    # Genome
    genome_d = None
    if isfile(genome):
        config['reference_fasta'] = genome
        genome = splitext_plus(basename(genome))[0]
    elif loc:
        config['reference_fasta'] = get_ref_file(genome, loc=loc)
        genome_d = get_genomes_d(genome, loc=loc)
    else:
        critical(f'Genome {genome}: fasta file does not exist, or cannot automatically find it by location.')

    # Truth set
    if isfile(truth):
        config['truth_variants'] = abspath(truth)
    elif genome_d:
        truth_set_d = genome_d.get('truth_sets', {}).get(truth)
        if not truth_set_d:
            critical(f'First argument must be either a VCF file, or a value from:'
                     f' {", ".join(genome_d.get("truth_sets").keys())}.'
                     f' Truth set "{truth}" was not found in the file system or in hpc.py'
                     f' for genome "{genome}" at file system "{loc.name}"')

        config['truth_variants'] = truth_set_d['vcf']
        if 'bed' in truth_set_d:
            config['truth_regions'] = truth_set_d['bed']
    else:
        critical(f'Truth set {truth}: file does not exist, or cannot automatically find it by location.')

    f = tempfile.NamedTemporaryFile(mode='wt', delete=False)
    yaml.dump(config, f)
    f.close()

    cmd = (f'snakemake ' +
           f'--snakefile {join(package_path(), "Snakefile")} ' +
           f'--printshellcmds ' +
          (f'--directory {output_dir} ' if output_dir else ' ') +
           f'--configfile {f.name} '
           f'--jobs {jobs} '
           )
    print(cmd)
    os.system(cmd)
    if output_dir:
        out_file = join(output_dir, 'report.tsv')
        if isfile(out_file):
            print(f'Results are in "{output_dir}" folder. E.g. final report saved to "{output_dir}/report.tsv"')


def stats_to_df(stat_by_sname):
    idx = pd.MultiIndex.from_arrays([
        ['Sample', 'SNP', 'SNP', 'SNP', 'SNP',  'SNP'   , 'INDEL', 'INDEL', 'INDEL' , 'INDEL', 'INDEL'],
        [''      , 'TP' , 'FP' , 'FN' , 'Prec', 'Recall', 'TP'   , 'FP'   , 'FN'    , 'Prec' , 'Recall']
        ],
        names=['1', '2'])

    data = []
    s_truth = i_truth = None
    for sname, stats in stat_by_sname.items():
        s_truth, s_tp, s_fp, s_fn, s_prec, s_rec, i_truth, i_tp, i_fp, i_fn, i_prec, i_rec = stats
        data.append({
            ('Sample', ''): sname,
            ('SNP', 'TP'): int(s_tp),
            ('SNP', 'FP'): int(s_fp),
            ('SNP', 'FN'): int(s_fn),
            ('SNP', 'Prec'): float(s_prec),  # TP/called
            ('SNP', 'Recall'): float(s_rec),  # TP/truth
            ('INDEL', 'TP'): int(i_tp),
            ('INDEL', 'FP'): int(i_fp),
            ('INDEL', 'FN'): int(i_fn),
            ('INDEL', 'Prec'): float(i_prec),
            ('INDEL', 'Recall'): float(i_rec)
        })
    data.append({
        ('Sample', ''): 'Truth',
        ('SNP', 'TP'): int(s_truth),
        ('SNP', 'FP'): 0,
        ('SNP', 'FN'): int(s_truth),
        ('SNP', 'Prec'): 1.0,
        ('SNP', 'Recall'): 1.0,
        ('INDEL', 'TP'): int(i_truth),
        ('INDEL', 'FP'): 0,
        ('INDEL', 'FN'): int(i_truth),
        ('INDEL', 'Prec'): 1.0,
        ('INDEL', 'Recall'): 1.0
    })
    return pd.DataFrame(data, columns=idx)


def dislay_stats_df(df):
    """ Pretty-printing the table on the screen
    """
    with pd.option_context(
            'display.max_rows', None,
            'display.max_columns', None,
            'display.width', None,
            'display.float_format', lambda v: '{:,.2f}%'.format(100.0*v)
            ):
        print(df.to_string(index=True))
