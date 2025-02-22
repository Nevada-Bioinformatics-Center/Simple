#!/bin/bash
#pipeline for mapping EMS mutants
#bug report to Guy Wachsman gw57@duke.edu

#exec 3>&1 4>&2
#trap 'exec 2>&4 1>&3' 0 1 2 3
#exec 1>log.out 2>&1

#reading variables
source ./scripts/simple_variables.sh

##Create folders if not made
if ! [ -d ./output/ ]; then
    mkdir output
fi

if ! [ -d ./refs/ ]; then
    mkdir refs
fi

#creating a log file for the input commands; I also wanted to have logs for the output but some of the stdout are super long
cat ./scripts/simple.sh > ./output/log.txt
cat ./scripts/analysis3.R >> ./output/log.txt

##DEPRECATED - In favor of conda environments
## conda create -n simple -c bioconda samtools bwa picard snpeff
## conda activate simple
## Need to manually install GATK as it isn't just a JAR now
##install programs bwa and samtools
#cd programs/bwa-0.7.12
#make clean 
#make
#
#cd ../samtools-0.1.19/
#make clean
#make
#
#cd ../../

#downloading & creating fasta file
fasta_link=`awk -v var="$my_species" 'match($1, var) {print $2}' ./scripts/data_base.txt`

if ! [ -f ./refs/$my_species.fa ]; then
  echo "Downloading reference FASTA file"
  curl -o ./refs/$my_species.fa.gz $fasta_link
  gzip -d ./refs/$my_species.fa.gz
fi

#replacing roman numerals in numbers
if [ $my_species = "caenorhabditis_elegans" ]; then
    awk '{gsub(/^[\>][I]$/, ">1", $1); gsub(/^[\>][I][I]$/, ">2", $1); gsub(/^[\>][I][I][I]$/, ">3", $1); gsub(/^[\>][I][V]$/, ">4", $1); gsub(/^[\>][V]$/, ">5", $1);print}' ./refs/$my_species.fa > ./refs/$my_species.1.fa
fi

if [ -f ./refs/$my_species.1.fa ]; then 
    mv ./refs/$my_species.1.fa ./refs/$my_species.fa
fi

#leaving only chromosomes (no scafolds or contiges)
awk '/[Ss]caffold/ || /[Cc]ontig/ {exit} {print}' ./refs/$my_species.fa > ./refs/$my_species.chrs.fa
fa=./refs/$my_species.chrs.fa

#downloading & creating knownsnps file
knownsnps_link=`awk -v var="$my_species" 'match($1, var) {print $3}' ./scripts/data_base.txt`
if ! [ -f ./refs/$my_species.vcf ]; then
  echo "Downloading known SNPs VCF"
  curl -o ./refs/$my_species.vcf.gz -Lk $knownsnps_link
  gzip -d ./refs/$my_species.vcf.gz
fi

#snpEff "link"
snpEff_link=`awk -v var="$my_species" 'match($1, var) {print $4}' ./scripts/data_base.txt`

#reference input files that are necessary to run the prograns
knownsnps=./refs/$my_species.vcf
#ftp://ftp.ensemblgenomes.org/pub/plants/release-31/vcf/arabidopsis_thaliana/arabidopsis_thaliana.vcf.gz
snpEffDB=$snpEff_link #paste the snpEff annotated genome name

####creating reference files####
##Adding logic to not recreate files
#creating .fai file
if ! [ -f ./refs/$my_species.fa.fai ]; then
    echo "Creating samtools faidx index"
    samtools faidx $fa
fi
#creating bwa index files
if ! [ -f ./refs/$my_species.chrs.fa.bwt ]; then
    echo "Creating BWA index"
    bwa index -p $my_species.chrs.fa -a is $fa
    mv $my_species.chrs.* refs/
fi

#generating dict file for GATK
##OLD WAY
#picard CreateSequenceDictionary R=$fa O=refs/$my_species.chrs.dict
if ! [ -f ./refs/$my_species.chrs.dict ]; then
    echo "Creating Seq Dictionary"
    picard CreateSequenceDictionary -R $fa -O refs/$my_species.chrs.dict
fi

#mapping w/ BWA
##ORIGINAL
#bwa mem -t 2 -M $fa ${mut_files[*]} > output/$mut.sam &
#bwa mem -t 2 -M $fa ${wt_files[*]} > output/$wt.sam
#wait


if ! [ -f ./output/$mut.bam ]; then
    echo "Mapping with BWA and creating BAM files"
    bwa mem -t 3 -M $fa ${mut_files[*]} | samtools view -bS - > output/$mut.bam &
    bwa mem -t 3 -M $fa ${wt_files[*]}  | samtools view -bS - > output/$wt.bam
    wait
fi

##DEPRECATED WITH NEW PIPED METHOD ABOVE
##due to old samtools version this step is probably necessary
#samtools view -bSh output/$mut.sam > output/$mut.bam &
#samtools view -bSh output/$wt.sam > output/$wt.bam
#wait

#rm -r output/*.sam

#this step is probably needed only when you have paired-end; in any case it should come before coordinate sorting (next step) on name-sorted files
if ! [ -f ./output/$mut.fix.bam ]; then
    echo "Fixing Mate"
    samtools fixmate output/$mut.bam output/$mut.fix.bam &
    samtools fixmate output/$wt.bam output/$wt.fix.bam
    wait
fi

#sort by coordinates
if ! [ -f ./output/$mut.sort.bam ]; then
    echo "Sorting files"
    samtools sort output/$mut.fix.bam -o output/$mut.sort.bam &
    samtools sort output/$wt.fix.bam -o output/$wt.sort.bam
    wait
fi

#picard MarkDuplicates INPUT=output/$mut.sort.bam OUTPUT=output/$mut.sort.md.bam METRICS_FILE=output/$mut.matrics.txt ASSUME_SORTED=true &
#picard MarkDuplicates INPUT=output/$wt.sort.bam OUTPUT=output/$wt.sort.md.bam METRICS_FILE=output/$wt.matrics.txt ASSUME_SORTED=true
#wait
if ! [ -f ./output/$mut.sort.md.bam ]; then
    echo "Running Picard Mark Duplicates"
    picard MarkDuplicates -INPUT output/$mut.sort.bam -OUTPUT output/$mut.sort.md.bam -METRICS_FILE output/$mut.matrics.txt -ASSUME_SORTED true &
    picard MarkDuplicates -INPUT output/$wt.sort.bam -OUTPUT output/$wt.sort.md.bam -METRICS_FILE output/$wt.matrics.txt -ASSUME_SORTED true
    wait
fi

#this part is just to add header for further gatk tools
#picard AddOrReplaceReadGroups INPUT=output/$mut.sort.md.bam OUTPUT=output/$mut.sort.md.rg.bam RGLB=$mut RGPL=illumina RGSM=$mut RGPU=run1 SORT_ORDER=coordinate &
#picard AddOrReplaceReadGroups INPUT=output/$wt.sort.md.bam OUTPUT=output/$wt.sort.md.rg.bam RGLB=$wt RGPL=illumina RGSM=$wt RGPU=run1 SORT_ORDER=coordinate
#wait
if ! [ -f ./output/$mut.sort.md.rg.bam ]; then
    echo "Running Picard AddOrReplaceReadGroups"
    picard AddOrReplaceReadGroups -INPUT output/$mut.sort.md.bam -OUTPUT output/$mut.sort.md.rg.bam -RGLB $mut -RGPL illumina -RGSM $mut -RGPU run1 -SORT_ORDER coordinate &
    picard AddOrReplaceReadGroups -INPUT output/$wt.sort.md.bam -OUTPUT output/$wt.sort.md.rg.bam -RGLB $wt -RGPL illumina -RGSM $wt -RGPU run1 -SORT_ORDER coordinate
    wait
fi

if ! [ -f ./output/$mut.sort.md.rg.bam.bai ]; then
    echo "Running Picard BuildBamIndex"
    picard BuildBamIndex INPUT=output/$mut.sort.md.rg.bam OUTPUT=output/$mut.sort.md.rg.bam.bai &
    picard BuildBamIndex INPUT=output/$wt.sort.md.rg.bam OUTPUT=output/$wt.sort.md.rg.bam.bai
    wait
    #picard BuildBamIndex -INPUT output/$mut.sort.md.rg.bam &
    #picard BuildBamIndex -INPUT output/$wt.sort.md.rg.bam
    #wait
fi

#Variant calling using GATK HC extra parameters
#java -Xmx2g -jar programs/GenomeAnalysisTK.jar -T HaplotypeCaller -R $fa -I output/$mut.sort.md.rg.bam -I output/$wt.sort.md.rg.bam -o output/$line.hc.vcf -minReadsPerAlignStart 7 -gt_mode DISCOVERY -out_mode EMIT_ALL_SITES -writeFullFormat -stand_emit_conf 10 -stand_call_conf 10 -nct 2 -variant_index_type LINEAR -variant_index_parameter 128000 -allowPotentiallyMisencodedQuals #the last argument is necessary for old sequencing results where the quality scores do not match the HC restriction: https://www.biostars.org/p/94637/; I also tried --fix_misencoded_quality_scores -fixMisencodedQuals from the same link but I received an error message. "Bad input: while fixing mis-encoded base qualities we encountered a read that was correctly encoded; we cannot handle such a mixture of reads so unfortunately the BAM must be fixed with some other tool"
if ! [ -f ./output/$line.hc.vcf ]; then
    echo "Running GATK HaplotypeCaller"
    #gatk HaplotypeCaller -R $fa -I output/$mut.sort.md.rg.bam -I output/$wt.sort.md.rg.bam -O output/$line.hc.vcf -minReadsPerAlignStart 7 -gt_mode DISCOVERY -out_mode EMIT_ALL_SITES -writeFullFormat -stand_emit_conf 10 -stand_call_conf 10 -nct 2 -variant_index_type LINEAR -variant_index_parameter 128000 -allowPotentiallyMisencodedQuals 
    gatk HaplotypeCaller -R $fa -I output/$mut.sort.md.rg.bam -I output/$wt.sort.md.rg.bam -O output/$line.hc.vcf --output-mode EMIT_ALL_ACTIVE_SITES -stand-call-conf 10 
fi

############prepering for R#########################
#Exclude indels from a VCF
#java -Xmx2g -jar programs/GenomeAnalysisTK.jar -R $fa -T SelectVariants --variant output/$line.hc.vcf -o output/$line.selvars.vcf --selectTypeToInclude SNP

#now make it into a table
if ! [ -f ./output/$line.table ]; then
    echo "Running GATK VariantsToTable"
    gatk VariantsToTable -R $fa -V output/$line.hc.vcf -F CHROM -F POS -F REF -F ALT -GF GT -GF AD -GF DP -GF GQ -O output/$line.table
fi

####################################################################################################################################################
########################################now let's find the best candidates##########################################################################

#snpEff
if ! [ -f ./output/$line.se.vcf ]; then
    echo "Running snpEff"
    #snpEff -c programs/snpEff/snpEff.config $snpEffDB -s output/snpEff_summary.html output/$line.hc.vcf > output/$line.se.vcf
    snpEff  $snpEffDB -s output/snpEff_summary.html output/$line.hc.vcf > output/$line.se.vcf
fi


###%%%%%%% JEN %%%%%%%%%%
#and finally, get only the SNPs that are ref/ref or ref/alt in the wt bulk and alt/alt in the mut bulk for recessive mutations
#for the case of dominant mutations should be ref/ref in the wt bulk and ref/alt or alt/alt in the mutant bulk
#column 10 is mutant bulk
#column 11 is WT bulk
echo "Running AWK filtering commands"
if [ $mutation = "recessive" ]; then
	grep -v '^##' output/$line.se.vcf | awk 'BEGIN{FS=" "; OFS=" "} $1~/#CHROM/ || $10~/^1\/1/ && ($11~/^1\/0/ || $11~/^0\/0/ || $11~/^0\/1/) && $1~/^[0-9X]*$/ && /splice_acceptor_variant|splice_donor_variant|splice_region_variant|stop_lost|start_lost|stop_gained|missense_variant|coding_sequence_variant|inframe_insertion|disruptive_inframe_insertion|inframe_deletion|disruptive_inframe_deletion|exon_variant|exon_loss_variant|exon_loss_variant|duplication|inversion|frameshift_variant|feature_ablation|duplication|gene_fusion|bidirectional_gene_fusion|rearranged_at_DNA_level|miRNA|initiator_codon_variant|start_retained/ {$3=$7=""; print $0}' | sed 's/  */ /g' | awk '{split($9,a,":"); split(a[2],b,","); if (b[1]>b[2] || $1~/#CHROM/) print $0}' > output/$line.cands2.txt
else
	grep -v '^##' output/$line.se.vcf | awk 'BEGIN{FS=" "; OFS=" "} $1~/#CHROM/ || ($10~/^0\/1/ || $10~/^1\/0/ || $10~/^1\/1/) && $11~/^0\/0/ && $1~/^[0-9X]*$/ && /splice_acceptor_variant|splice_donor_variant|splice_region_variant|stop_lost|start_lost|stop_gained|missense_variant|coding_sequence_variant|inframe_insertion|disruptive_inframe_insertion|inframe_deletion|disruptive_inframe_deletion|exon_variant|exon_loss_variant|exon_loss_variant|duplication|inversion|frameshift_variant|feature_ablation|duplication|gene_fusion|bidirectional_gene_fusion|rearranged_at_DNA_level|miRNA|initiator_codon_variant|start_retained/ {$3=$7=""; print $0}' | sed 's/  */ /g' | awk '{split($9,a,":"); split(a[2],b,","); if (b[1]>b[2] || $1~/#CHROM/) print $0}' > output/$line.cands2.txt
fi

#awk 'FNR==NR{a[$1$2];next};!($1$2 in a) || $1~/#CHROM/' $knownsnps output/$line.cands2.txt > output/$line.cands3.txt

#getting things a bit more organized and only the relevant data from cands3
printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "chr" "pos" "ref" "alt" "mutation_effect" "gene" "At_num" "CDS_change" "protein_change" "$mut.ref" "$mut.alt" "$wt.ref" "$wt.alt" > output/$line.cands44.txt
awk 'BEGIN{OFS="\t"} NR>1 {split($6,a,"|");split($8,b,":"); split(b[2],c,","); split($9,d,":"); split(d[2],e,","); gsub("c.", "", a[10]); gsub("p\\.", "", a[11]); print $1, $2, $3, $4, a[2], a[4], a[5], a[10], a[11], c[1], c[2], e[1], e[2]}' output/$line.cands2.txt | awk '$0!~/\./ && (($10+$11)>4) && (($12+$13)>4)' >> output/$line.cands44.txt

# JEN changed file name below
sort -k1,1 -k2 -n output/$line.cands44.txt > output/$line.candidates.txt

####################################################################################################################################################
####################################################################################################################################################

####################################################################################################################################################
####################################################################################################################################################
#this command will make it ready to run w/ R to produce Manhatten plot
printf "%s\t" "CHR" "POS" "REF" "ALT" "mut_GT" "mut.ref" "mut.alt" "mut.DP" "mut.GQ" "wt.GT" "wt.ref" "wt.alt" "wt.DP" "wt.GQ" > output/$line.plot.txt; printf "\n" >> output/$line.plot.txt
awk '$1~/^[0-9X]*$/ && $5~/^[AGCT]/ && $9~/^[AGCT]/ && $0 !~ /NA/ && $2 !~ /\./ && $3 !~ /\./ {gsub(/\,/, "\t"); print}' output/$line.table | awk '$6+$11>0 && $8>3 && $13>3' >> output/$line.plot.txt

#and finally, just get rid of known snps
awk 'FNR==NR{a[$1$2$4$5];next};!($1$2$3$4 in a)' $knownsnps output/$line.plot.txt > output/$line.plot.no_known_snps.txt

#get the snps in SnpEff format
awk 'FNR==NR{a[$1$2];next};($1$2 in a)' output/$line.plot.no_known_snps.txt output/$line.se.vcf > output/$line.plot2.txt
awk '{$3=$7=""; print $0}' output/$line.plot2.txt | sed 's/  */ /g' > output/$line.plot3.txt
awk '$3!~/\./ && $4!~/\./' output/$line.plot3.txt > output/$line.plot33.txt
printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "chr" "pos" "ref" "alt" "mutation_effect" "gene" "At_num" "CDS_change" "protein_change" "mut.ref" "mut.alt" "wt.ref" "wt.alt" > output/$line.plot44.txt
awk 'BEGIN{OFS="\t"} {split($6,a,"|");split($8,b,":"); split(b[2],c,","); split($9,d,":"); split(d[2],e,","); gsub("c.", "", a[10]); gsub("p\\.", "", a[11]); print $1, $2, $3, $4, a[2], a[4], a[5], a[10], a[11], c[1], c[2], e[1], e[2]}' output/$line.plot33.txt >> output/$line.plot44.txt

##JEN changed filename below
sort -k1,1 -k2 -n output/$line.plot44.txt > output/$line.allSNPs.txt

####################################################################################################################################################
####################################################################################################################################################
#print cands that originate from a non-ref nucleotide
grep -v '^##' output/$line.se.vcf | awk 'BEGIN{FS=" "; OFS=" "} $1~/#CHROM/ || ($10~/^2\/2/ && $11!~/^2\/2/) && $1~/^[0-9X]*$/ && /splice_acceptor_variant|splice_donor_variant|splice_region_variant|stop_lost|start_lost|stop_gained|missense_variant|coding_sequence_variant|inframe_insertion|disruptive_inframe_insertion|inframe_deletion|disruptive_inframe_deletion|exon_variant|exon_loss_variant|exon_loss_variant|duplication|inversion|frameshift_variant|feature_ablation|duplication|gene_fusion|bidirectional_gene_fusion|rearranged_at_DNA_level|miRNA|initiator_codon_variant|start_retained/ {$3=$7=""; print $0}' | sed 's/  */ /g' | awk '{split($9,a,":"); split(a[2],b,","); if (b[1]>b[2] || $1~/#CHROM/) print $0}' > output/$line.cands_alt2.txt
awk 'FNR==NR{a[$1$2$4$5];next};!($1$2$3$4 in a) || $1~/#CHROM/' $knownsnps output/$line.cands_alt2.txt > output/$line.cands_alt3.txt

#getting things a bit more organized and only the relevant data from cands3
printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "chr" "pos" "ref" "alt" "mutation_effect" "gene" "At_num" "CDS_change" "protein_change" "$mut.ref" "$mut.alt" "$wt.ref" "$wt.alt" > output/$line.cands_alt4.txt
awk 'BEGIN{OFS="\t"} NR>1 {split($6,a,"|");split($8,b,":"); split(b[2],c,","); split($9,d,":"); split(d[2],e,","); gsub("c.", "", a[10]); gsub("p\\.", "", a[11]); print $1, $2, $3, $4, a[2], a[4], a[5], a[10], a[11], c[1], c[2], e[1], e[2]}' output/$line.cands_alt3.txt | awk '$0!~/\./ && (($10+$11)>4) && (($12+$13)>4)' >> output/$line.cands_alt4.txt

####################################################################################################################################################
####################################################################################################################################################

#JEN added the line argument below
Rscript ./scripts/analysis3.R $line

#archiving files
echo "Moving Intermediate files to archive"
if ! [ -d ./archive/ ]; then
    mkdir archive
fi
mv ./output/* ./archive/
mv ./archive/$line.*pdf* ./archive/*allSNPs.txt ./archive/$line.candidates.txt ./output/

echo "$(tput setaf 1)Simple $(tput setaf 3)is $(tput setaf 4)done"




