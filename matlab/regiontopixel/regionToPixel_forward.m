function[scoresSP, labelsTargetSP, mapSP] = regionToPixel_forward(scoresAll, regionToPixelAux, inverseLabelFreqs, oldWeightMode, replicateUnpureSPs)
% [scoresSP, labelsTargetSP, mapSP] = regionToPixel_forward(scoresAll, regionToPixelAux, inverseLabelFreqs, oldWeightMode, replicateUnpureSPs)
%
% Go from a region level to a pixel level.
% (to be able to compute a loss there)
%
% Copyright by Holger Caesar, 2015

% Move to CPU
gpuMode = isa(scoresAll, 'gpuArray');
if gpuMode,
    scoresAll = gather(scoresAll);
end;

% Check inputs
assert(~any(isnan(scoresAll(:)) | isinf(scoresAll(:))));

% Reshape scores
scoresAll = reshape(scoresAll, [size(scoresAll, 3), size(scoresAll, 4)]);

% Get additional batch info
overlapListAll = regionToPixelAux.overlapListAll;

% Init
labelCount = size(scoresAll, 1);
spCount = size(overlapListAll, 2);
boxCount = size(scoresAll, 2);
scoresSP = nan(labelCount, spCount, 'single'); % Note that zeros will be counted anyways!
mapSP = nan(labelCount, spCount);

% Compute maximum scores and map/mask for the backward pass
for spIdx = 1 : spCount,
    ancestors = find(overlapListAll(:, spIdx));
    if ~isempty(ancestors),
        % For each label, compute the ancestor with the highest score
        [scoresSP(:, spIdx), curInds] = max(scoresAll(:, ancestors), [], 2);
        curBoxInds = ancestors(curInds);
        mapSP(:, spIdx) = curBoxInds;
    end;
end;

% Compute sample target labels and weights
isTest = ~(isfield(regionToPixelAux, 'spLabelHistos') && ~isempty(regionToPixelAux.spLabelHistos));
if isTest,
    % Set dummy outputs
    labelsTargetSP = [];
    mapSP = [];
else
    % Get input fields
    labelPixelFreqs = regionToPixelAux.labelPixelFreqs;
    spLabelHistos   = regionToPixelAux.spLabelHistos;
    imageCountTrn   = regionToPixelAux.imageCountTrn;
    
    % Check inputs
    assert(all(size(labelPixelFreqs) == [labelCount, 1]));
    assert(all(size(spLabelHistos) == [spCount, labelCount]));
    
    % If an SP has no label, we need to remove it from scores, map, target and
    % pixelSizes
    nonEmptySPs = ~any(isnan(scoresSP))';
    scoresSP = scoresSP(:, nonEmptySPs);
    mapSP = mapSP(:, nonEmptySPs);
    spLabelHistos = spLabelHistos(nonEmptySPs, :);
    spCount = sum(nonEmptySPs);
    assert(spCount >= 1);
    
    % Replicate regions with multiple labels
    % (change: scoresSP, labelsTargetSP, mapSP, pixelSizesSP)
    if replicateUnpureSPs,
        scoresSPRepl = cell(spCount, 1);
        labelsTargetSPRepl = cell(spCount, 1);
        mapSPRepl = cell(spCount, 1);
        pixelSizesSPRepl = cell(spCount, 1);
        for spIdx = 1 : spCount,
            replInds = find(spLabelHistos(spIdx, :))';
            replCount = numel(replInds);
            scoresSPRepl{spIdx} = repmat(scoresSP(:, spIdx)', [replCount, 1]);
            mapSPRepl{spIdx} = repmat(mapSP(:, spIdx)', [replCount, 1]);
            labelsTargetSPRepl{spIdx} = replInds;
            pixelSizesSPRepl{spIdx} = spLabelHistos(spIdx, replInds)';
        end;
        scoresSP = cell2mat(scoresSPRepl)';
        mapSP = cell2mat(mapSPRepl)';
        labelsTargetSP = cell2mat(labelsTargetSPRepl);
        pixelSizesSP = cell2mat(pixelSizesSPRepl);
    else
        [~, labelsTargetSP] = max(spLabelHistos, [], 2);
        pixelSizesSP = sum(spLabelHistos, 2);
    end;
    
    % Renormalize label weights to have on average a weight == boxCount
    if oldWeightMode,
        if inverseLabelFreqs,
             weightsSP = (pixelSizesSP * imageCountTrn) ./ (labelPixelFreqs(labelsTargetSP) * labelCount);
             weightsSP = weightsSP ./ sum(weightsSP);
        else
            pixelWeightsSP = pixelSizesSP ./ sum(pixelSizesSP);
            weightsSP = pixelWeightsSP;
        end;
    else
        if inverseLabelFreqs,
            weightsSP = (pixelSizesSP * imageCountTrn) ./ (labelPixelFreqs(labelsTargetSP) * labelCount);
        else
            weightsSP = (pixelSizesSP * imageCountTrn)  / sum(labelPixelFreqs);
        end;
    end;
    weightsSP = weightsSP * boxCount;
    
    % Reshape and append label weights
    labelsTargetSP = reshape(labelsTargetSP, 1, 1, 1, []);
    weightsSP = reshape(weightsSP, 1, 1, 1, []);
    labelsTargetSP = cat(3, labelsTargetSP, weightsSP);
    
    % Final checks (only in train, in test NANs are fine)
    assert(~any(isnan(scoresSP(:)) | isinf(scoresSP(:))));
end;

% Reshape the scores
scoresSP = reshape(scoresSP, [1, 1, size(scoresSP)]);

% Convert outputs back to GPU if necessary
if gpuMode,
    scoresSP = gpuArray(scoresSP);
end;