#!/usr/bin/env nextflow

import groovy.json.JsonBuilder
nextflow.enable.dsl = 2

include { fastq_ingress } from './lib/fastqingress'


// Workflow processes
process combineFilterFastq {
    label "wf_human_sv"
    cpus 1
    input:
        tuple path(directory), val(sample_name)
    output:
        path "${sample_name}.fastq", emit: filtered
        path "${sample_name}.stats", emit: stats
    """
    fastcat \
        -a $params.min_len \
        -b $params.max_len \
        -q 10 \
        -s ${sample_name} \
        -r ${sample_name}.stats \
        -x ${directory} > ${sample_name}.fastq
    """
}


process indexLRA {
    label "wf_human_sv"
    cpus 1
    input:
        file reference
    output:
        path "${reference.simpleName}", emit: ref
        path "${reference.simpleName}.gli", emit: lra_index
        path "${reference.simpleName}.mmi", emit: mmi_index
    script:
        def simpleRef = reference.simpleName
    """
    cp -L $reference $simpleRef
    if [[ $reference == *.gz ]]
    then
        rm $reference
        mv $simpleRef ${simpleRef}.gz
        gunzip ${simpleRef}.gz
    fi
    lra index -ONT $simpleRef
    """
}


process mapLRA {
    label "wf_human_sv"
    cpus params.threads
    input:
        file reference
        file lra_index
        file mmi_index
        file reads
    output:
        path "*lra.bam", emit: bam
        path "*lra.bam.bai", emit: bam_index
    script:
        def name = reads.simpleName
    """
    catfishq -r $reads --max_mbp $params.max_bp \
    | seqtk seq -A - \
    | lra align -ONT -t $task.cpus $reference - -p s \
    | samtools addreplacerg -r \"@RG\tID:$name\tSM:$name\" - \
    | samtools sort -@ $task.cpus -o ${name}.lra.bam -
    samtools index -@ $task.cpus ${name}.lra.bam
    """
}


process cuteSV {
    label "wf_human_sv"
    cpus params.threads
    input:
        file bam
        file bam_index
        file reference
    output:
        path "*.cutesv.vcf", emit: vcf
    script:
        def name = bam.simpleName
    """
    cuteSV \
        --threads $task.cpus \
        --sample $name \
        --retain_work_dir \
        --report_readid \
        --genotype \
        --min_size $params.min_sv_length \
        --max_size $params.max_sv_length \
        --min_support $params.min_read_support_limit \
        --max_cluster_bias_INS $params.max_cluster_bias_INS \
        --diff_ratio_merging_INS $params.diff_ratio_merging_INS \
        --max_cluster_bias_DEL $params.max_cluster_bias_DEL \
        --diff_ratio_merging_DEL $params.diff_ratio_merging_DEL \
        $bam \
        $reference \
        ${name}.cutesv.vcf \
        .
	"""
}


process mosdepth {
    label "wf_human_sv"
    cpus params.threads
    input:
        file bam
        file bam_index
        file target_bed
    output:
        path "*.regions.bed.gz", emit: mosdepth_bed
    script:
        def name = bam.simpleName
        def target_bed = target_bed.name != 'OPTIONAL_FILE' ? "${target_bed}" : 1000000
    """
	mosdepth \
        -x \
        -t $task.cpus \
        -b $target_bed \
        $name \
        $bam
	"""
}


process filterCalls {
    label "wf_human_sv"
    cpus 1
    input:
        file vcf
        file mosdepth_bed
        file target_bed
    output:
        path "*.filtered.vcf", emit: vcf
    script:
        def name = vcf.simpleName
        def sv_types_joined = params.sv_types.split(',').join(" ")
        def target_bed = target_bed.name != 'OPTIONAL_FILE' ? "--target_bedfile ${target_bed}" : ""
    """
    get_filter_calls_command.py \
        $target_bed \
        --vcf $vcf \
        --depth_bedfile $mosdepth_bed \
        --min_sv_length $params.min_sv_length \
        --max_sv_length $params.max_sv_length \
        --sv_types $sv_types_joined \
        --min_read_support $params.min_read_support \
        --min_read_support_limit $params.min_read_support_limit > filter.sh

    bash filter.sh > ${name}.filtered.vcf
	"""
}


process sortVCF {
    label "wf_human_sv"
    cpus 1
    input:
        file vcf
    output:
        path "*.sorted.vcf", emit: vcf
    script:
        def name = vcf.simpleName
    """
    vcfsort $vcf > ${name}.sorted.vcf
    """
}


process indexVCF {
    label "wf_human_sv"
    cpus 1
    input:
        file vcf
    output:
        path "${vcf}.gz", emit: vcf_gz
        path "${vcf}.gz.tbi", emit: vcf_tbi
    """
    cat $vcf | bgziptabix ${vcf}.gz
    """
}


// The following processes are for the benchmarking
// pathway of this pipeline. Please see the documentation
// for further details. 
process getTruthset {
    label "wf_human_sv"
    cpus 1
    output:
        path "*.vcf.gz", emit: truthset_vcf_gz
        path "*.vcf.gz.tbi",  emit: truthset_vcf_tbi
        path "*.bed",  emit: truthset_bed
    """
    for item in $params.truthset_vcf $params.truthset_index $params.truthset_bed
    do
        if wget -q --method=HEAD \$item;
        then
            echo "Downloading \$item."
            wget \$item
        elif [ -f \$item ];
        then
            echo "Found \$item locally."
            cp \$item .
        else
            echo "\$item cannot be found."
            exit 1
        fi
    done
    """
}


process intersectCallsHighconf {
    label "wf_human_sv"
    cpus 1
    input:
        file calls_vcf
        file truthset_bed
    output:
        path "*.eval_highconf.bed", emit: calls_highconf_bed
    script:
        def name = calls_vcf.simpleName
    """
    bedtools intersect \
        -a $truthset_bed \
        -b $calls_vcf \
        -u > ${name}.eval_highconf.bed

    if [ ! -s eval_highconf.bed ]
    then
        echo "No overlaps found between calls and truthset"
        echo "Chr names in your reference and truthset may differ"
        exit 1
    fi
    """
}


process getAllChromosomesBed {
    label "wf_human_sv"
    cpus 1
    input:
        file reference
    output:
        path "allChromosomes.bed", emit: all_chromosomes_bed
    """
    faidx --transform bed $reference > allChromosomes.bed
    """
}


process excludeNonIndels {
    label "wf_human_sv"
    cpus 1
    input:
        file calls_vcf
    output:
        path "*.noIndels.vcf.gz", emit: indels_only_vcf_gz
        path "*.noIndels.vcf.gz.tbi", emit: indels_only_vcf_tbi
    script:
        def name = calls_vcf.simpleName
    """
    zcat $calls_vcf \
    | sed 's/SVTYPE=DUP/SVTYPE=INS/g' \
    | bcftools view -i '(SVTYPE = \"INS\" || SVTYPE = \"DEL\")' \
    | bgziptabix ${name}.noIndels.vcf.gz
    """
}


process truvari {
    label "wf_human_sv"
    cpus 1
    input:
        file reference
        file calls_vcf
        file calls_vcf_tbi
        file truthset_vcf
        file truthset_vcf_tbi
        file include_bed
    output:
        path "*.summary.json", emit: truvari_json
    script:
        def name = calls_vcf.simpleName
    """
    TRUVARI=\$(which truvari)
    python \$TRUVARI bench \
        --passonly \
        --pctsim 0 \
        -b $truthset_vcf \
        -c $calls_vcf \
        -f $reference \
        -o $name \
        --includebed $include_bed
    mv ${name}/summary.txt ${name}.summary.json
    """
}


process getVersions {
    label "wf_human_sv"
    cpus 1
    output:
        path "versions.txt"
    script:
    """
    python -c "import pysam; print(f'pysam,{pysam.__version__}')" >> versions.txt
    TRUVARI=\$(which truvari)
    python \$TRUVARI version | sed 's/ /,/' >> versions.txt
    mosdepth --version | sed 's/ /,/' >> versions.txt
    fastcat --version | sed 's/^/fastcat,/' >> versions.txt
    cuteSV --version | head -n 1 | sed 's/ /,/' >> versions.txt
    bcftools --version | head -n 1 | sed 's/ /,/' >> versions.txt
    bedtools --version | head -n 1 | sed 's/ /,/' >> versions.txt
    samtools --version | head -n 1 | sed 's/ /,/' >> versions.txt
    echo `lra -v | head -n 2 | tail -1 | cut -d ':' -f 2 | sed 's/ /lra,/'` >> versions.txt
    echo `seqtk 2>&1 | head -n 3 | tail -n 1 | cut -d ':' -f 2 | sed 's/ /seqtk,/'` >> versions.txt
    """
}


process getParams {
    label "wf_human_sv"
    cpus 1
    output:
        path "params.json"
    script:
        def paramsJSON = new JsonBuilder(params).toPrettyString()
    """
    # Output nextflow params object to JSON
    echo '$paramsJSON' > params.json
    """
}


process report {
    label "wf_human_sv"
    cpus 1
    input:
        file vcf
        file read_stats
        file eval_json
        file versions
        path "params.json"
    output:
        path "wf-human-sv-*.html", emit: html
    script:
        def name = vcf.simpleName
        def report_name = "wf-human-sv-" + params.report_name + '.html'
        def evalResults = eval_json.name != 'OPTIONAL_FILE' ? "--eval_results ${eval_json}" : ""
    """
    report.py \
        $report_name \
        --vcf $vcf \
        --reads_summary $read_stats \
        --params params.json \
        --versions $versions \
        --revision $workflow.revision \
        --commit $workflow.commitId \
        $evalResults 
    """
}


// See https://github.com/nextflow-io/nextflow/issues/1636
// This is the only way to publish files from a workflow whilst
// decoupling the publish from the process steps.
process output {
    // publish inputs to output directory
    label "pysam"
    publishDir "${params.out_dir}", mode: 'copy', pattern: "*"
    input:
        path fname
    output:
        path fname
    """
    echo "Writing output files"
    """
}


// Workflow main pipeline
workflow pipeline {
    take:
        samples
        reference
        target
    main:
        samples = combineFilterFastq(samples)
        indexLRA(reference)
        mapLRA(indexLRA.out.ref, indexLRA.out.lra_index, indexLRA.out.mmi_index, samples.filtered)
        cuteSV(mapLRA.out.bam, mapLRA.out.bam_index, indexLRA.out.ref)
        mosdepth(mapLRA.out.bam, mapLRA.out.bam_index, target)
        filterCalls(cuteSV.out.vcf, mosdepth.out.mosdepth_bed, target)
        sortVCF(filterCalls.out.vcf)
        indexVCF(sortVCF.out.vcf)
    emit:
        reads = samples.filtered
        read_stats = samples.stats
        ref = indexLRA.out.ref
        vcf = indexVCF.out.vcf_gz
        vcf_index = indexVCF.out.vcf_tbi
        bam = mapLRA.out.bam
        bam_index = mapLRA.out.bam_index
}


workflow standard {
    take:
        samples
        reference
        target
        optional_file
    main:
        println("================================")
        println("Running workflow: standard mode.")
        standard = pipeline(samples, reference, target)
        software_versions = getVersions()
        workflow_params = getParams()
        report(
            standard.vcf.collect(),
            standard.read_stats.collect(),
            optional_file,
            software_versions, 
            workflow_params)
        results = report.out.html.concat(
            standard.vcf, 
            standard.vcf_index, 
            standard.bam, 
            standard.bam_index)
    emit:
        results
}


workflow benchmark {
    take:
        samples
        reference
        target
    main:
        println("=================================")
        println("Running workflow: benchmark mode.")
        standard = pipeline(samples, reference, target)
        truthset = getTruthset()
        filtered = excludeNonIndels(standard.vcf)
        if (params.benchmarkUseTruthsetBed) {
            bedToUse = truthset.truthset_bed
        } else {
            bedToUse = getAllChromosomesBed(
                reference).all_chromosomes_bed
        }
        truvari(
            standard.ref,
            filtered.indels_only_vcf_gz,
            filtered.indels_only_vcf_tbi,
            truthset.truthset_vcf_gz,
            truthset.truthset_vcf_tbi,
            bedToUse)
        software_versions = getVersions()
        workflow_params = getParams()
        report(
            standard.vcf.collect(),
            standard.read_stats.collect(),
            truvari.out.truvari_json.collect(),
            software_versions,
            workflow_params)
        results = report.out.html.concat(
            standard.vcf,
            standard.vcf_index, 
            standard.bam, 
            standard.bam_index)
    emit:
        results
}


// workflow entrypoint
WorkflowMain.initialise(workflow, params, log)

workflow {

    // Ready the optional file
    OPTIONAL = file("$projectDir/data/OPTIONAL_FILE")

    // Checking user parameters
    println("=================================")
    println("Checking inputs")

    // Acquire reads
    samples = fastq_ingress(
        params.fastq, params.out_dir, params.samples, params.sanitize_fastq)

    // Acquire reference
    reference = file(params.reference, type: "file")
    if (!reference.exists()) {
        println("--reference: File doesn't exist, check path.")
        exit 1
    }

    // Check for target bedfile
    target = file(params.target_bedfile, type: "file")
    if (!target.exists()) {
        target = OPTIONAL
    }

    // Check min_read_support
    min_read_support = params.min_read_support
    if (!min_read_support.toString().isInteger() && min_read_support !== 'auto') {
        println("--min_read_support: Must be integer or 'auto'.")
        exit 1
    }

    // Print all params
    println("=================================")
    println("Summarising parameters")
    params.each { it -> println("> $it.key: $it.value") }

    // Execute workflow
    if (params.benchmark) {
        results = benchmark(samples, reference, target)
    } else {
        results = standard(samples, reference, target, OPTIONAL)
    }
    output(results)
}

