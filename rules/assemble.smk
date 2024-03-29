import os

include: "get_container.smk"


rule transfer_contigs:
    """ Take the assemblies from 10X, made from scRNA-seq reads """
    input:
        '{base}/vdj/{sample}/outs/filtered_contig.fasta'
    output:
        '{base}/vdj/{sample}/outs/BCR_transcripts.fasta'
    threads: 1
    params:
        name="xfer_contifs",
        partition=config['partition'],
        scratch=config['scratch'] if 'scratch' in config and config['scratch'] else '$PWD',
        scripts_dir=os.path.join(workflow.basedir, 'scripts')
    resources:
        mem_mb=5000
    conda:
        os.path.join(workflow.basedir, 'envs/miniconda.yaml')
    shell:
        "python {params.scripts_dir}/xfer_10X_contigs.py "
        "{input} {output}"


rule blast_constant_region:
    """ BLAST assemblies against a constant region database
        Notes:
        * Database contains both heavy and light chain constant regions
        * Tuned for high quality matches (megablast + wordsize)
    """
    input:
        rules.transfer_contigs.output
    output:
        '{base}/vdj/{sample}/outs/constant_region_blast.tsv'
    threads: 1
    params:
        name="blast_iso",
        partition=config['partition'],
        ig_receptor='IG' if config['receptor'] == 'BCR' else 'TR',
        const_db_dir=os.path.join(workflow.basedir,
                                  'resources/assembly/constant_region_db')
    resources:
        mem_mb=5300
    conda:
        os.path.join(workflow.basedir, 'envs/miniconda.yaml')
    shell:  'blastn '
            '-db {params.const_db_dir}/imgt_{config[species]}_{params.ig_receptor}_combined.fasta '
            '-query {input} -outfmt "6 qseqid sacc length pident mismatch gaps qstart qend score evalue" '
            '-out {output} -task megablast -word_size 20 -num_threads {threads} -max_target_seqs 3'


rule igblast_changeo:
    """ Run IgBLAST and parse the output with Change-O into tabular form
        Notes:
        * Uses the immcantation docker image via Singularity
        * Creates empty output if the input fasta is empty to avoid errors
    """
    input:
        img=rules.get_immcantation_image.output,
        assembly=rules.transfer_contigs.output
    output:
        '{base}/vdj/{sample}/outs/transcripts.fmt7',
        '{base}/vdj/{sample}/outs/igblast_db-pass.tab'
    threads: 1
    params:
        name='igblast',
        partition=config['partition'],
        container_type=config['container_type'],
        singularity_pre_cmd="" if 'singularity_pre_cmd' not in config else config['singularity_pre_cmd']
    resources:
        mem_mb=5300
    run:
        if os.stat(str(input.assembly)).st_size == 0:
            print('Input assembly fasta is empty. Touching empty outputs')
            for out in output:
                with open(str(out), 'w') as outfile:
                    pass
        else:
            if params.container_type == 'docker':
                # docker needs to bind an absolute path
                abs_dir_path = os.path.dirname(os.path.abspath(str(input.assembly)))
                assembly_name = os.path.basename(str(input.assembly))
                # run docker with current user:group (avoids permissions issues)
                shell(  'docker run -v {abs_dir_path}:/data:z -u `stat -c "%u:%g" $PWD` '
                        'kleinstein/immcantation:2.6.0 changeo-igblast '
                        '-o /data -s /data/{assembly_name} -n igblast '
                        '-p 1 -g {config[species]} -t ig')
            else:
                # singularity
                shell(  "{params.singularity_pre_cmd} "
                        "singularity exec -B $(dirname {output[0]}):/data "
                        "{input.img} changeo-igblast "
                        "-o /data -s {input.assembly} -n igblast "
                        "-p 1 -g {config[species]} -t ig")


rule merge_changeo_constant:
    """ Merge constant region blast results into change-o output"""
    input:
        changeo=rules.igblast_changeo.output[1],
        constant=rules.blast_constant_region.output
    output:
        '{base}/vdj/{sample}/outs/igblast_db-pass_const-merge.tsv'
    threads: 1
    params:
        name="merge_changeo_constant",
        partition=config['partition'],
        scripts_dir=os.path.join(workflow.basedir, 'scripts')
    resources:
        mem_mb=5300
    conda:
        os.path.join(workflow.basedir, 'envs/miniconda.yaml')
    shell:
        "python {params.scripts_dir}/merge_changeo_constant.py "
        "{input.changeo} {input.constant} {output}"


rule combine_assemblies:
    """ Join assemblies from all samples into a single table """
    input:
        expand('{base}/vdj/{sample}/outs/igblast_db-pass_const-merge.tsv',
                zip,
                base=samplesheet.base.values.tolist(),
                sample=samplesheet.samplename.values.tolist())
    output:
        'combined_assemblies.tsv'
    threads: 1
    params:
        name="combine_assemblies",
        partition=config['partition'],
        scripts_dir=os.path.join(workflow.basedir, 'scripts')
    resources:
        mem_mb=5000
    conda:
        os.path.join(workflow.basedir, 'envs/miniconda.yaml')
    shell:
        "python {params.scripts_dir}/combine_assemblies.py {config[samplesheet]} {output}"

