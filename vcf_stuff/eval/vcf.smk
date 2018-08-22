# Snakemake file for evaluation of a set of VCF files against a truth set.
# Handles multiallelic, normalization, inconsistent sample names.

# Usage:
# snakemake -p --configfile=config.yaml

import os
import gzip
import csv

from ngs_utils.file_utils import add_suffix
from ngs_utils.vcf_utils import get_tumor_sample_name
from hpc_utils.hpc import get_loc
from vcf_stuff.vcf_normalisation import make_normalise_cmd
from vcf_stuff.eval import stats_to_df, dislay_stats_df, f_measure


rule all:
    input:
        'eval/report.tsv'
    output:
        'report.tsv'
    shell:
        'ln -s {input} {output}'


def merge_regions():
    samples_regions = config.get('sample_regions')
    truth_regions = config['truth_regions'] if 'truth_regions' in config else None

    output = 'narrow/regions.bed'
    if samples_regions and truth_regions:
        shell('bedops -i <(sort-bed {truth_regions}) <(sort-bed {samples_regions}) > {output}')
        return output
    elif truth_regions:
        shell('sort-bed {truth_regions} > {output}')
        return output
    elif samples_regions:
        shell('sort-bed {samples_regions} > {output}')
        return output
    else:
        return None

# def get_regions_input(_):
#     ret = [f for f in (truth_regions, samples_regions) if f]
#     print("ret: " + str(ret))
#     return ret

# rule prep_regions:
#     input:
#         get_regions_input
#     output:
#         'regions/regions.bed'
#     run:
#         if samples_regions and truth_regions:
#             shell('bedops -i <(sort-bed {truth_regions}) <(sort-bed {samples_regions}) > {output}')
#         elif truth_regions:
#             shell('sort-bed {truth_regions} > {output}')
#         elif samples_regions:
#             shell('sort-bed {samples_regions} > {output}')

##########################
######### NARROW #########
# Extracts target regions and PASSed calls:
rule narrow_samples_to_regions_and_pass:
    input:
        lambda wildcards: config['samples'][wildcards.sample]
    output:
        'narrow/{sample}.regions.pass.vcf.gz'
    run:
        regions = merge_regions()
        regions = ('-T ' + regions) if regions else ''
        shell('bcftools view {input} {regions} -f .,PASS -Oz -o {output}')

if config.get('anno_dp_af'):
    # Propagate FORMAT fields into INFO (using NORMAL_ prefix for normal samples matches):
    rule anno_dp_af:
        input:
            rules.narrow_samples_to_regions_and_pass.output[0]
        output:
            'narrow/{sample}.regions.pass.anno.vcf.gz'
        shell:
            'pcgr_prep {input} | bgzip -c > {output}'

    anno_rule = rules.anno_dp_af

elif config.get('remove_anno'):
    rule remove_anno:
        input:
            rules.narrow_samples_to_regions_and_pass.output[0]
        output:
            'narrow/{sample}.regions.pass.clean.vcf.gz'
        shell:
            'bcftools annotate -x INFO,FORMAT {input} | bgzip -c > {output}'

    anno_rule = rules.remove_anno

else:
    anno_rule = rules.narrow_samples_to_regions_and_pass

# Extract only tumor sample and tabix:
rule narrow_samples_to_tumor_sample:
    input:
        anno_rule.output[0]
    output:
        add_suffix(anno_rule.output[0], 'tumor')
    run:
        sn = get_tumor_sample_name(input[0])
        assert sn
        shell('bcftools view -s {sn} {input} -Oz -o {output} && tabix -p vcf -f {output}')

# Extract target, PASSed and tumor sample from the truth VCF:
rule narrow_truth_to_target:
    input:
        config['truth_variants']
    output:
        'narrow/truth_variants.vcf.gz'
    run:
        regions = merge_regions()
        regions = ('-T ' + regions) if regions else ''
        shell('bcftools view {input} {regions} -Ou | bcftools annotate -x INFO,FORMAT -Oz -o {output} && tabix -p vcf -f {output}')

############################
######### NORMALSE #########
# Normalise query VCFs:
rule normalise_sample:
    input:
        vcf = rules.narrow_samples_to_tumor_sample.output[0],
        ref = config['reference_fasta']
    output:
        vcf = 'normalise/{sample}/{sample}.vcf.gz',
        tbi = 'normalise/{sample}/{sample}.vcf.gz.tbi'
    shell:
        make_normalise_cmd('{input.vcf}', '{output[0]}', '{input.ref}')

# Normalise truth VCFs:
rule normalise_truth:
    input:
        vcf = rules.narrow_truth_to_target.output[0],
        ref = config['reference_fasta']
    output:
        vcf = 'normalise/truth_variants.vcf.gz',
        tbi = 'normalise/truth_variants.vcf.gz.tbi'
    shell:
        make_normalise_cmd('{input.vcf}', '{output[0]}', '{input.ref}')

TRICKY_TOML = ''
if config.get('anno_tricky'):
    # Overlap normalised calls with tricky regions and annotate into INFO:
    tricky_bed = os.path.join(get_loc().extras, 'GRCh37_tricky.bed.gz')
    TRICKY_TOML = f'''[[annotation]]
    file="{tricky_bed}"
    names=["TRICKY"]
    columns=[4]
    ops=["self"]'''

rule prep_tricky_toml:
    output:
        'normalise/tricky_vcfanno.toml'
    params:
        toml_text = TRICKY_TOML.replace('\n', r'\\n').replace('"', r'\"'),
    shell:
        'printf "{params.toml_text}" > {output}'

rule anno_tricky_sample:
    input:
        vcf = rules.normalise_sample.output[0],
        toml = rules.prep_tricky_toml.output
    output:
        vcf = 'normalise/{sample}/{sample}.tricky.vcf.gz',
        tbi = 'normalise/{sample}/{sample}.tricky.vcf.gz.tbi'
    shell:
        'vcfanno {input.toml} {input.vcf} | bgzip -c > {output.vcf} && tabix -p vcf -f {output.vcf}'

# Overlap normalised truth calls with tricky regions and annotate into INFO:
rule anno_tricky_truth:
    input:
        vcf = rules.normalise_truth.output[0],
        toml = rules.prep_tricky_toml.output
    output:
        vcf = 'normalise/truth_variants.tricky.vcf.gz',
        tbi = 'normalise/truth_variants.tricky.vcf.gz.tbi'
    shell:
        'vcfanno {input.toml} {input.vcf} | bgzip -c > {output.vcf} && tabix -p vcf -f {output.vcf}'

############################
######### EVALUATE #########
# Run bcftools isec to get separate VCFs with TP, FN and FN:
rule bcftools_isec:
    input:
        sample_vcf = rules.anno_tricky_sample.output.vcf if config.get('anno_tricky') else rules.normalise_sample.output.vcf,
        sample_tbi = rules.anno_tricky_sample.output.tbi if config.get('anno_tricky') else rules.normalise_sample.output.tbi,
        truth_vcf = rules.anno_tricky_truth.output.vcf   if config.get('anno_tricky') else rules.normalise_truth.output.vcf,
        truth_tbi = rules.anno_tricky_truth.output.tbi   if config.get('anno_tricky') else rules.normalise_truth.output.tbi
    params:
        output_dir = 'eval/{sample}_bcftools_isec'
    output:
        fp = 'eval/{sample}_bcftools_isec/0000.vcf',
        fn = 'eval/{sample}_bcftools_isec/0001.vcf',
        tp = 'eval/{sample}_bcftools_isec/0002.vcf'
    run:
        shell('bcftools isec {input.sample_vcf} {input.truth_vcf} -p {params.output_dir}')

def count_variants(vcf):
    snps = 0
    indels = 0
    with (gzip.open(vcf) if vcf.endswith('.gz') else open(vcf)) as f:
        for l in [l for l in f if not l.startswith('#')]:
            _, _, _, ref, alt = l.split('\t')[:5]
            if len(ref) == len(alt) == 1:
                snps += 1
            else:
                indels += 1
    return snps, indels

# Count TP, FN and FN VCFs to get stats for each sample:
rule eval:
    input:
        fp = rules.bcftools_isec.output.fp,
        fn = rules.bcftools_isec.output.fn,
        tp = rules.bcftools_isec.output.tp
    output:
        'eval/{sample}_stats.tsv'
    run:
        fp_snps, fp_inds = count_variants(input.fp)
        fn_snps, fn_inds = count_variants(input.fn)
        tp_snps, tp_inds = count_variants(input.tp)

        with open(output[0], 'w') as f:
            writer = csv.writer(f, delimiter='\t')
            writer.writerow([
                '#SNP TP', 'SNP FP', 'SNP FN', 'SNP Recall', 'SNP Precision',
                 'IND TP', 'IND FP', 'IND FN', 'IND Recall', 'IND Precision'
            ])
            # https://en.wikipedia.org/wiki/Precision_and_recall :
            # precision                  = tp / (tp + fp)
            # recall = sensitivity = tpr = tp / (tp + fn)

            snps_truth = tp_snps + fn_snps
            snps_recall = tp_snps / snps_truth if snps_truth else 0
            snps_called = tp_snps + fp_snps
            snps_prec = tp_snps / snps_called if snps_called else 0

            inds_truth = tp_inds + fn_inds
            inds_recall = tp_inds / inds_truth if inds_truth else 0
            inds_called = tp_inds + fp_inds
            inds_prec = tp_inds / inds_called if inds_called else 0

            snps_f1 = f_measure(1, snps_prec, snps_recall)
            snps_f2 = f_measure(2, snps_prec, snps_recall)
            snps_f3 = f_measure(3, snps_prec, snps_recall)

            inds_f1 = f_measure(1, inds_prec, inds_recall)
            inds_f2 = f_measure(2, inds_prec, inds_recall)
            inds_f3 = f_measure(3, inds_prec, inds_recall)

            writer.writerow([
                snps_truth, tp_snps, fp_snps, fn_snps, snps_recall, snps_prec, snps_f1, snps_f2, snps_f3,
                inds_truth, tp_inds, fp_inds, fn_inds, inds_recall, inds_prec, inds_f1, inds_f2, inds_f3,
            ])

# Combine all stats to get single report:
rule report:
    input:
        stats_files = expand(rules.eval.output, sample=sorted(config['samples'].keys()))
        # sompy_files = expand(rules.sompy.output, sample=sorted(config['samples'].keys()))
    output:
        'eval/report.tsv'
    params:
        samples = sorted(config['samples'].keys())
    run:
        stats_by_sname = dict()
        for stats_file, sname in zip(input.stats_files, params.samples):
            with open(stats_file) as f:
                stats_by_sname[sname] = f.readlines()[1].strip().split('\t')
        df = stats_to_df(stats_by_sname)

        dislay_stats_df(df)

        # Writing raw data to the TSV file
        with open(output[0], 'w') as out_f:
            df.to_csv(out_f, sep='\t', index=False)


# rule eval:
#     input:
#         rules.index_samples.output,
#         rules.index_truth.output,
#         regions = rules.prep_target.output,
#         truth_vcf = rules.narrow_truth_to_target.output,
#         sample_vcf = rules.narrow_samples_to_target.output
#     output:
#         '{sample}/{sample}.re.a/weighted_roc.tsv.gz'
#     shell:
#         '{rtgeval}/run-eval -s {sdf}'
#         ' -b {input.regions}'
#         ' {input.truth_vcf}'
#         ' {input.sample_vcf}'

# rule count_truth:
#     input:
#         truth_variants
#     output:
#         snps = 'truth.snps',
#         indels = 'truth.indels'
#     run:
#         snps, indels = count_variants(truth_variants)
#         with open(output.snps, 'w') as o:
#             o.write(snps)
#         with open(output.indels, 'w') as o:
#             o.write(indels)

# rule report:
#     input:
#         stats_files = expand(rules.eval.output, sample=config['samples'].keys()),
#         truth_snps = rules.count_truth.output.snps,
#         truth_indels = rules.count_truth.output.indels
#     output:
#         'report.tsv'
#     params:
#         samples = config['samples']
#     run:
#         truth_snps = int(open(input.truth_snps).read())
#         truth_indels = int(open(input.truth_indels).read())

#         out_lines = []
#         out_lines.append(['', 'SNP', ''  , ''  , 'INDEL', ''  , ''  ])
#         out_lines.append(['', 'TP' , 'FP', 'FN', 'TP'   , 'FP', 'FN'])

#         for stats_file, sname in zip(input.stats_files, params.samples):
#             data = defaultdict(dict)
#             with open(stats_file) as f:
#                 for l in f:
#                     if l:
#                         event_type, change_type, metric, val = l.strip().split()[:4]
#                         if event_type == 'allelic':
#                             try:
#                                 val = int(val)
#                             except ValueError:
#                                 val = float(val)
#                             data[change_type][metric] = val
#             pprint.pprint(data)
#             try:
#                 out_lines.append([sname, truth_snps   - data['SNP']['FN'],   data['SNP']['FP'],   data['SNP']['FN'],
#                                          truth_indels - data['INDEL']['FN'], data['INDEL']['FP'], data['INDEL']['FN']])
#             except KeyError:
#                 print('Some of the required data for ' + sname + ' not found in ' + fp)

#         with open(output[0], 'w') as out_f:
#             for fields in out_lines:
#                 print(fields)
#                 out_f.write('\t'.join(map(str, fields)) + '\n')


