#!/usr/bin/env nextflow 

// build CDS object from query expression data 
QUERY_10X_DIR = Channel.fromPath(params.query_10x_dir)
process build_query_cds {

    conda "${baseDir}/envs/monocle3-cli.yaml"

    errorStrategy { task.exitStatus == 130 || task.exitStatus == 137  ? 'retry' : 'finish' }   
    maxRetries 5
    memory { 16.GB * task.attempt }

    input:
        file(query_10x_dir) from QUERY_10X_DIR

    output:
        file("query_cds_obj.rds") into QUERY_CDS_OBJECT

    """
    monocle3 create query_cds_obj.rds\
            --expression-matrix ${query_10x_dir}/matrix.mtx\
            --cell-metadata ${query_10x_dir}/barcodes.tsv\
            --gene-annotation ${query_10x_dir}/genes.tsv
    """ 

}

// run pre-trained classifiers against the query data set
CLASSIFIERS = Channel.fromPath(params.classifiers).map{ f -> tuple("${f.simpleName}", f) } 
process run_garnett_predictions{
    conda "${baseDir}/envs/garnett-cli.yaml"

    errorStrategy { task.exitStatus == 130 || task.exitStatus == 137  ? 'retry' : 'finish' }   
    maxRetries 5
    memory { 16.GB * task.attempt }
    
    input:
        set val(acc), file(classifier) from CLASSIFIERS
        file(query_cds_obj) from QUERY_CDS_OBJECT.first()
        
    output:
        set val(acc), file("${acc}_predicted.rds") into PRED_LABELS_OBJ


    """
    garnett_classify_cells.R\
            --cds-object ${query_cds_obj}\
            --classifier-object ${classifier}\
            --database ${params.database}\
            --cds-gene-id-type ${params.cds_gene_id_type}\
            --cluster-extend ${params.cluster_extend}\
            --rank-prob-ratio ${params.rank_prob_ratio}\
            --cds-output-obj ${acc}_predicted.rds
    """   
}

process get_final_tables {
    conda "${baseDir}/envs/garnett-cli.yaml"

    input:
        set val(acc), file(pred_labs_object) from PRED_LABELS_OBJ        

    output:
        file("${acc}_final_labs.tsv") into PRED_LABELS_TBLS

    """
    garnett_get_std_output.R\
            --input-object ${pred_labs_object}\
            --predicted-cell-type-field ${params.predicted_cell_type_field}\
            --output-file-path ${acc}_labs.tsv


    # add metadata fields to output table
    echo "# dataset ${acc}" > ${acc}_final_labs.tsv
    echo "# tool garnett" >> ${acc}_final_labs.tsv
    cat ${acc}_labs.tsv >> ${acc}_final_labs.tsv
    """
}


process combine_labels{
    input:
        file(labels) from PRED_LABELS_TBLS.collect()

    output:
        file("${params.label_dir}") into GARNETT_LABELS_DIR


    """
    mkdir -p ${params.label_dir}
    for file in ${labels}
    do
        mv \$file ${params.label_dir}
    done
    """
}

process select_top_labs {
    conda "${baseDir}/envs/cell-types-analysis.yaml" 
    publishDir "${params.results_dir}", mode: 'copy'

    input:
        file(label_dir) from GARNETT_LABELS_DIR

    output:
        file("garnett_output.tsv") into GARNETT_TOP_LABS

    """
    combine_tool_outputs.R\
        --input-dir ${label_dir}\
        --top-labels-num 2\
        --output-table garnett_output.tsv
    """
}











